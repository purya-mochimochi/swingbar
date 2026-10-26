addon.name      = 'swingbar'
addon.author    = 'purya-mochimochi (Logic adapted from maybeLynd)'
addon.version   = '1.2'
addon.desc      = 'Auto-attack swing bar with dynamic hit counter & Ready! display'
addon.link      = 'https://github.com/purya-mochimochi/swingbar'

local imgui  = require('imgui')
local socket = require('socket')

-- 描画・スタイル設定
local settings = {
    visible     = true,
    show_text   = true,
    show_tphits = true,
    opacity     = 0.88,
    width       = 175.0,  -- バーの横幅
    height      = 5.0,    -- バーの太さ
    x           = nil,
    y           = nil,
}

-- タイマー管理テーブル
local swing  = { last = nil, est = 3.0, landed = false }

-- TP追跡用テーブル
local tp_state = {
    last_tp    = 0,
    tp_per_hit = nil,
}

local swap_warmup                        = 0    -- 武器変更後の測定カウンター（0で通常稼働）
local last_main_id                       = nil  -- 直前のメイン武器アイテムID
local SWING_MIN, SWING_FLOOR, SWING_CEIL = 0.8, 1.0, 10.0
local LATENCY_OFFSET                     = 0.15 -- 描画・パケット遅延の先行補正（秒）
local reposition_pending                 = false

-- 状態異常バフID定義
local BUFF_SLEEP_1    = 2
local BUFF_PARALYSIS  = 4
local BUFF_PETRIFY    = 7
local BUFF_CHARM      = 14
local BUFF_SLEEP_2    = 19
local BUFF_TERROR     = 193

local INCAPACITATED_BUFFS = {
    [BUFF_SLEEP_1] = true,
    [BUFF_SLEEP_2] = true,
    [BUFF_PETRIFY] = true,
    [BUFF_TERROR]  = true,
    [BUFF_CHARM]   = true,
}

local is_incapacitated_prev = false
local freeze_start_time     = nil
local action_pause_start    = nil -- アビリティ等の使用中にバーを一時停止する時刻
local action_pause_duration = 2.0 -- 行動ごとの硬直時間（秒）
local ACTION_PAUSE_TIMEOUT  = 8.0 
local skip_next_est_update  = false

-- 現在装備しているメイン武器のアイテムIDを取得
local function get_main_weapon_id()
    local inventory = AshitaCore:GetMemoryManager():GetInventory()
    if not inventory then return nil end

    -- Equipment slot 0 = Main hand
    local equip = inventory:GetEquippedItem(0)
    if not equip or equip.Index == 0 then return 0 end

    local container = bit.band(equip.Index, 0xFF00) / 0x0100
    local index     = bit.band(equip.Index, 0x00FF)
    local item      = inventory:GetContainerItem(container, index)
    if not item then return 0 end

    return item.Id
end

-- プレイヤーのバフ状態チェック
local function check_player_buffs()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if not player then return false, false end

    local incapacitated = false
    local paralyzed     = false

    local buffs = player:GetBuffs()
    if buffs then
        for i = 0, 31 do
            local buff = buffs[i]
            if buff and buff > 0 and buff ~= 255 then
                if INCAPACITATED_BUFFS[buff] then
                    incapacitated = true
                elseif buff == BUFF_PARALYSIS then
                    paralyzed = true
                end
            end
        end
    end
    return incapacitated, paralyzed
end

-- 抜刀状態（Engaged: 1）の判定
local function is_engaged()
    local party = AshitaCore:GetMemoryManager():GetParty()
    local entity = AshitaCore:GetMemoryManager():GetEntity()
    if not party or not entity then return false end

    local my_index = party:GetMemberTargetIndex(0)
    if not my_index or my_index == 0 then return false end

    return entity:GetStatus(my_index) == 1
end

-- 自キャラのサーバーID取得
local function get_my_id()
    local party = AshitaCore:GetMemoryManager():GetParty()
    if not party then return 0 end
    return party:GetMemberServerId(0)
end

-- 自キャラの現在TP取得
local function get_my_tp()
    local party = AshitaCore:GetMemoryManager():GetParty()
    if not party then return 0 end

    local tp = party:GetMemberTP(0)
    if tp then
        return tp
    end

    return 0
end

-- 近接スイング進行度計算 (0.0 ～ 1.0)
local function get_swing_progress()
    local equipped_id = get_main_weapon_id()

    -- 装備アイテムIDの変更を常時監視（戦闘中・非戦闘中問わず）
    if equipped_id and last_main_id and equipped_id ~= last_main_id then
        tp_state.tp_per_hit = nil
        swap_warmup = 3
    end
    last_main_id = equipped_id

    if not is_engaged() then
        swing.landed = false
        freeze_start_time = nil
        is_incapacitated_prev = false
        action_pause_start = nil
        -- 納刀時：武器が変わっていない限り swap_warmup や tp_per_hit はリセットしない
        return nil
    end
    if not swing.last or not swing.landed then return nil end

    local now = socket.gettime()
    local is_incap, _ = check_player_buffs()

    if is_incap then
        if not is_incapacitated_prev then
            freeze_start_time = now
            is_incapacitated_prev = true
        end
    else
        if is_incapacitated_prev and freeze_start_time then
            local frozen_duration = now - freeze_start_time
            swing.last = swing.last + frozen_duration
            freeze_start_time = nil
            is_incapacitated_prev = false
            skip_next_est_update = true
        end
    end

    -- アビリティ等の硬直処理
    if action_pause_start then
        local paused_for = now - action_pause_start
        if paused_for >= action_pause_duration or paused_for >= ACTION_PAUSE_TIMEOUT then
            if swing.last then
                swing.last = swing.last + paused_for
            end
            action_pause_start = nil
            skip_next_est_update = true
        end
    end

    local reference_time = freeze_start_time or action_pause_start or now
    if reference_time - swing.last > 30 then return nil end

    -- 描画・ネットワーク遅延を補正してバーを前進させる
    local elapsed = (reference_time - swing.last) + LATENCY_OFFSET
    return math.max(0.0, math.min(1.0, elapsed / (swing.est or 3.0)))
end

-- パケット受信イベント (Action: 0x028 / Message: 0x029)
ashita.events.register('packet_in', 'packet_in_cb', function (e)
    local my_id = get_my_id()
    if not my_id or my_id == 0 then return end

    if e.id == 0x029 then
        return
    end

    if e.id ~= 0x028 then return end

    local actor_id = struct.unpack('I', e.data, 0x05 + 1)
    if actor_id ~= my_id then return end

    local byte_0A = struct.unpack('B', e.data, 0x0A + 1)
    local category = bit.band(bit.rshift(byte_0A, 2), 0x0F)
    local now = socket.gettime()

    -- Category 1: 通常近接攻撃
    if category == 1 then
        if swing.last and (now - swing.last) < SWING_MIN and not action_pause_start then return end

        -- アビリティ等で停止していた時間を除外
        if action_pause_start then
            if swing.last then
                swing.last = swing.last + (now - action_pause_start)
            end
            action_pause_start = nil
            skip_next_est_update = true
        end

        -- 獲得TPの計測とヒット数（Single / DA / TA）の判定
        local current_tp = get_my_tp()
        local hit_count = 1
        local is_multi_attack = false
        local tp_gain = 0

        -- 戦闘中にTPが急激に減った場合（装備変更マクロ等）のフォールバック検知
        if tp_state.last_tp and current_tp < tp_state.last_tp and (tp_state.last_tp - current_tp) > 50 then
            tp_state.tp_per_hit = nil
            swap_warmup = 3
        end

        if tp_state.last_tp and current_tp > tp_state.last_tp then
            tp_gain = current_tp - tp_state.last_tp

            if tp_gain >= 30 and tp_gain <= 450 then
                if not tp_state.tp_per_hit then
                    -- 初回スイング時：獲得TPが異常に高い（DA/TA）場合の按分推定
                    if tp_gain >= 280 then
                        hit_count = 3
                        tp_state.tp_per_hit = math.floor(tp_gain / 3)
                        is_multi_attack = true
                    elseif tp_gain >= 190 then
                        hit_count = 2
                        tp_state.tp_per_hit = math.floor(tp_gain / 2)
                        is_multi_attack = true
                    else
                        hit_count = 1
                        tp_state.tp_per_hit = tp_gain
                    end
                else
                    -- 基準TPがある場合：倍率からヒット数を判定
                    if tp_gain >= math.floor(tp_state.tp_per_hit * 2.5) then
                        hit_count = 3
                        is_multi_attack = true
                    elseif tp_gain >= math.floor(tp_state.tp_per_hit * 1.5) then
                        hit_count = 2
                        is_multi_attack = true
                    elseif tp_gain < tp_state.tp_per_hit then
                        hit_count = 1
                        tp_state.tp_per_hit = tp_gain
                    elseif tp_gain <= tp_state.tp_per_hit * 1.15 then
                        hit_count = 1
                        tp_state.tp_per_hit = math.floor(tp_state.tp_per_hit * 0.8 + tp_gain * 0.2 + 0.5)
                    end
                end
            end
        end
        tp_state.last_tp = current_tp

        local _, is_para = check_player_buffs()

        if swing.last then
            local d = now - swing.last

            -- 【学習条件】
            -- 1. 適正ディレイ範囲内（1.0s ～ 10.0s）
            -- 2. 麻痺していない
            -- 3. アクション停止直後ではない
            if d >= SWING_FLOOR and d <= SWING_CEIL and not is_para and not skip_next_est_update then
                if swap_warmup > 0 then
                    swap_warmup = math.max(0, swap_warmup - hit_count)

                    if not swing.est or swing.est < SWING_FLOOR or swing.est > SWING_CEIL or swap_warmup >= 2 then
                        swing.est = d
                    else
                        swing.est = swing.est * 0.40 + d * 0.60
                    end
                elseif not is_multi_attack then
                    -- 定常時は「単発のみ」を厳密に学習
                    local diff = math.abs(d - swing.est)

                    if diff > 0.50 then
                        swing.est = swing.est * 0.30 + d * 0.70
                    else
                        swing.est = swing.est * 0.85 + d * 0.15
                    end
                end
                swing.est = math.max(SWING_FLOOR, math.min(SWING_CEIL, swing.est))
            end
            skip_next_est_update = false
        end

        swing.last = now
        swing.landed = true

    -- WS / 魔法 / ジョブアビリティの検知
    elseif category == 3 or category == 4 or category == 6 or
           category == 7 or category == 8 or category == 14 or
           category == 15 then
        skip_next_est_update = true
        tp_state.last_tp = get_my_tp()

        if swing.last and swing.landed and not action_pause_start then
            action_pause_start = now
            if category == 4 or category == 8 then
                action_pause_duration = 3.0
            else
                action_pause_duration = 2.0
            end
        end
    end
end)

-- ImGui レンダリング
ashita.events.register('d3d_present', 'd3d_present_cb', function ()
    if not settings.visible then return end

    local sprog = get_swing_progress()
    if not sprog then return end

    local flags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav
    )

    if reposition_pending and settings.x and settings.y then
        imgui.SetNextWindowPos({ settings.x, settings.y }, ImGuiCond_Always)
        reposition_pending = false
    end

    local bg_alpha    = math.max(0.0, math.min(1.0, settings.opacity))
    local frame_alpha = math.min(1.0, bg_alpha + 0.1)

    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.05, 0.05, 0.05, bg_alpha })
    imgui.PushStyleColor(ImGuiCol_Border,   { 0.00, 0.00, 0.00, 0.00 })
    imgui.PushStyleColor(ImGuiCol_FrameBg,  { 0.15, 0.15, 0.15, frame_alpha })

    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 6.0)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 10.0, 8.0 })
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0.0, 3.0 })
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 2.0)

    local is_incap, is_para = check_player_buffs()

    if imgui.Begin('##SwingBar_Window', true, flags) then
        if settings.show_text then
            if swap_warmup > 0 then
                imgui.TextColored({ 1.00, 0.80, 0.20, 1.00 }, 'Swap!')
                imgui.SameLine()
                imgui.TextColored({ 0.60, 0.60, 0.60, 1.00 }, string.format('   [%d]', swap_warmup))
            else
                local label_text = 'Attack'
                local label_col  = { 0.90, 0.90, 0.90, 1.00 }

                if is_incap then
                    label_text = 'Asleep'
                    label_col  = { 0.70, 0.70, 0.70, 1.00 }
                elseif is_para then
                    label_text = 'Paralyzed'
                    label_col  = { 1.00, 0.65, 0.20, 1.00 }
                end

                imgui.TextColored(label_col, label_text)
                imgui.SameLine()

                local time_str = string.format('   %.1fs', swing.est or 3.0)
                imgui.TextColored({ 0.20, 0.85, 0.30, 1.00 }, time_str)

                if settings.show_tphits then
                    local current_tp = get_my_tp()
                    if current_tp >= 1000 then
                        imgui.SameLine()
                        imgui.TextColored({ 1.00, 0.82, 0.20, 1.00 }, ' Ready!')
                    elseif tp_state.tp_per_hit and tp_state.tp_per_hit > 0 then
                        local needed = 1000 - current_tp
                        local left_swings = math.ceil(needed / tp_state.tp_per_hit)
                        local unit_str = (left_swings == 1) and 'hit' or 'hits'
                        imgui.SameLine()
                        imgui.TextColored({ 0.20, 0.85, 0.30, 1.00 }, string.format(' [%d%s]', left_swings, unit_str))
                    end
                end
            end
        end

        local bar_color = { 0.18, 0.80, 0.35, 1.00 }
        local bar_val   = sprog

        if swap_warmup > 0 then
            bar_color = { 0.30, 0.30, 0.30, 0.50 }
            bar_val   = 0.0
        elseif is_incap then
            bar_color = { 0.45, 0.45, 0.45, 0.90 }
        elseif is_para then
            bar_color = { 0.95, 0.60, 0.15, 1.00 }
        end

        imgui.PushStyleColor(ImGuiCol_PlotHistogram, bar_color)
        imgui.ProgressBar(bar_val, { settings.width, settings.height }, '')
        imgui.PopStyleColor(1)
    end
    imgui.End()

    imgui.PopStyleVar(4)
    imgui.PopStyleColor(3)
end)

-- ゲーム内コマンド
ashita.events.register('command', 'command_cb', function (e)
    local cmd_str = e.command
    if not cmd_str then return end

    local args = {}
    for word in cmd_str:gmatch('%S+') do
        table.insert(args, word)
    end

    if #args == 0 then return end

    local base_cmd = args[1]:lower()
    if base_cmd ~= '/sb' and base_cmd ~= '/swingbar' then
        return
    end

    e.blocked = true

    local function show_help()
        print('[SwingBar] Command List:')
        print('  /sb pos <x> <y>        - Move window to coordinates.')
        print('  /sb size <w> [h]       - Set bar width and height (e.g. /sb size 180 6).')
        print('  /sb opacity <0.0..1.0> - Set background opacity.')
        print('  /sb tp                 - Toggle remaining hits to 1000 TP.')
        print('  /sb text               - Toggle interval text.')
    end

    if #args == 1 or not args[2] then
        show_help()
        return
    end

    local sub_cmd = args[2]:lower()

    if sub_cmd == 'pos' then
        local x = tonumber(args[3])
        local y = tonumber(args[4])
        if x and y then
            settings.x = x
            settings.y = y
            reposition_pending = true
            print(string.format('[SwingBar] Window position set to X:%d, Y:%d', x, y))
        else
            print('[SwingBar] Usage: /sb pos <x> <y>')
        end
    elseif sub_cmd == 'size' or sub_cmd == 'scale' then
        local w = tonumber(args[3])
        local h = tonumber(args[4])
        if w then
            settings.width = math.max(80.0, math.min(500.0, w))
            if h then
                settings.height = math.max(2.0, math.min(30.0, h))
            end
            print(string.format('[SwingBar] Bar size set to Width:%.0f, Height:%.0f', settings.width, settings.height))
        else
            print('[SwingBar] Usage: /sb size <width> [height] (e.g. /sb size 180 6)')
        end
    elseif sub_cmd == 'opacity' or sub_cmd == 'alpha' then
        local val = tonumber(args[3])
        if val then
            settings.opacity = math.max(0.0, math.min(1.0, val))
            print(string.format('[SwingBar] Background opacity set to %.2f', settings.opacity))
        else
            print('[SwingBar] Usage: /sb opacity <0.0..1.0>')
        end
    elseif sub_cmd == 'tp' or sub_cmd == 'tphits' then
        settings.show_tphits = not settings.show_tphits
        print('[SwingBar] Remaining hits to 1000 TP: ' .. (settings.show_tphits and 'ON' or 'OFF'))
    elseif sub_cmd == 'text' then
        settings.show_text = not settings.show_text
        print('[SwingBar] Interval text: ' .. (settings.show_text and 'ON' or 'OFF'))
    else
        show_help()
    end
end)
