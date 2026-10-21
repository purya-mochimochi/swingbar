addon.name      = 'swingbar'
addon.author    = 'Chiro (Logic adapted from maybeLynd)'
addon.version   = '1.0'
addon.desc      = 'swing bar for ashita'
addon.link      = 'https://github.com/purya-mochimochi/swingbar'

local imgui  = require('imgui')
local socket = require('socket')

-- 描画・スタイル設定
local settings = {
    visible     = true,
    show_melee  = true,
    show_ranged = true,
    show_text   = true,
    width       = 160.0,
    height      = 5.0,
    x           = nil,
    y           = nil,
}

-- タイマー管理テーブル
local swing  = { last = nil, est = 3.0, hits = 1, landed = false }
local ranged = { last = nil, est = 5.0, hits = 1 }

local SWING_MIN, SWING_FLOOR, SWING_CEIL    = 0.3, 0.8, 10.0
local RANGED_MIN, RANGED_FLOOR, RANGED_CEIL = 0.3, 1.0, 20.0
local reposition_pending = false

-- 状態異常バフID定義（スタン 28 は除外）
local BUFF_SLEEP_1    = 2
local BUFF_PARALYSIS  = 4
local BUFF_PETRIFY    = 7
local BUFF_CHARM      = 14
local BUFF_SLEEP_2    = 19
local BUFF_TERROR     = 193

-- 行動停止系（持続する睡眠、石化、テラー、魅了）
local INCAPACITATED_BUFFS = {
    [BUFF_SLEEP_1] = true,
    [BUFF_SLEEP_2] = true,
    [BUFF_PETRIFY] = true,
    [BUFF_TERROR]  = true,
    [BUFF_CHARM]   = true,
}

local is_incapacitated_prev = false
local freeze_start_time     = nil
local skip_next_est_update  = false

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

-- 近接スイング進行度計算 (0.0 ～ 1.0)
local function get_swing_progress()
    if not is_engaged() then
        swing.landed = false
        freeze_start_time = nil
        is_incapacitated_prev = false
        return nil
    end
    if not swing.last or not swing.landed then return nil end

    local now = socket.gettime()
    local is_incap, _ = check_player_buffs()

    -- 睡眠・石化中の一時停止（フリーズ）処理
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

    local reference_time = freeze_start_time or now
    if reference_time - swing.last > 30 then return nil end
    return math.max(0.0, math.min(1.0, (reference_time - swing.last) / (swing.est or 3.0)))
end

-- 遠隔攻撃進行度計算 (0.0 ～ 1.0)
local function get_ranged_progress()
    if not is_engaged() or not ranged.last then return nil end
    local now = socket.gettime()
    if now - ranged.last > 30 then return nil end
    return math.max(0.0, math.min(1.0, (now - ranged.last) / (ranged.est or 5.0)))
end

-- パケット受信イベント (Action: 0x028 / Message: 0x029)
ashita.events.register('packet_in', 'packet_in_cb', function (e)
    local my_id = get_my_id()
    if not my_id or my_id == 0 then return end

    -- 麻痺ログの検知 (0x029)
    if e.id == 0x029 then
        local actor_id = struct.unpack('I', e.data, 0x05 + 1)
        if actor_id == my_id then
            local message_id = bit.band(struct.unpack('H', e.data, 0x19 + 1), 0x7FFF)
            if message_id == 29 then
                swing.last = socket.gettime()
                skip_next_est_update = true
            end
        end
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
        if swing.last and (now - swing.last) < SWING_MIN then return end

        local _, is_para = check_player_buffs()

        if swing.last then
            local d = now - swing.last

            -- 麻痺中、復帰直後、または魔法詠唱後でなければ予測ディレイを更新
            if not is_para and not skip_next_est_update then
                if not swing.est then
                    swing.est = math.min(SWING_CEIL, math.max(SWING_FLOOR, d))
                elseif d >= swing.est * 0.6 and d <= swing.est * 1.7 then
                    swing.est = swing.est * 0.7 + d * 0.3
                elseif d < swing.est * 0.6 then
                    swing.est = math.max(SWING_FLOOR, swing.est * 0.8 + d * 0.2)
                elseif d <= swing.est * 2.5 then
                    swing.est = math.min(SWING_CEIL, swing.est * 0.85 + d * 0.15)
                end
            end
            skip_next_est_update = false
        end
        swing.last = now
        swing.landed = true

    -- Category 2: 遠隔通常攻撃
    elseif category == 2 then
        if ranged.last and (now - ranged.last) < RANGED_MIN then return end

        if ranged.last then
            local d = now - ranged.last
            if not ranged.est then
                ranged.est = math.min(RANGED_CEIL, math.max(RANGED_FLOOR, d))
            elseif d >= ranged.est * 0.6 and d <= ranged.est * 1.7 then
                ranged.est = ranged.est * 0.7 + d * 0.3
            elseif d < ranged.est * 0.6 then
                ranged.est = math.max(RANGED_FLOOR, ranged.est * 0.8 + d * 0.2)
            elseif d <= ranged.est * 2.5 then
                ranged.est = math.min(RANGED_CEIL, ranged.est * 0.85 + d * 0.15)
            end
        end
        ranged.last = now

    -- 【追加】Category 4: 魔法詠唱完了 / Category 8: 魔法詠唱開始
    -- 魔法詠唱によって通常攻撃の間隔が伸びるため、次回の通常攻撃時はディレイ予測の学習をスキップ
    elseif category == 4 or category == 8 then
        skip_next_est_update = true

    -- 【追加】Category 3: ウェポンスキル発動
    -- WS直後の通常攻撃も間隔がズレるため同様にスキップ
    elseif category == 3 then
        skip_next_est_update = true
    end
end)

-- ImGui レンダリング
ashita.events.register('d3d_present', 'd3d_present_cb', function ()
    if not settings.visible then return end

    local sprog = settings.show_melee and get_swing_progress() or nil
    local rprog = settings.show_ranged and get_ranged_progress() or nil

    if not sprog and not rprog then return end

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

    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.05, 0.05, 0.05, 0.88 })
    imgui.PushStyleColor(ImGuiCol_Border,   { 0.00, 0.00, 0.00, 0.00 })
    imgui.PushStyleColor(ImGuiCol_FrameBg,  { 0.15, 0.15, 0.15, 0.90 })

    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 6.0)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 10.0, 8.0 })
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0.0, 3.0 })
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 2.0)

    local is_incap, is_para = check_player_buffs()

    if imgui.Begin('##SwingBar_Window', true, flags) then
        -- 近接攻撃バー
        if sprog then
            if settings.show_text then
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
            end

            local bar_color = { 0.18, 0.80, 0.35, 1.00 }
            if is_incap then
                bar_color = { 0.45, 0.45, 0.45, 0.90 }    -- 睡眠・石化時: 暗いグレー
            elseif is_para then
                bar_color = { 0.95, 0.60, 0.15, 1.00 }    -- 麻痺時: オレンジ
            end

            imgui.PushStyleColor(ImGuiCol_PlotHistogram, bar_color)
            imgui.ProgressBar(sprog, { settings.width, settings.height }, '')
            imgui.PopStyleColor(1)
        end

        -- 遠隔攻撃バー
        if rprog then
            if sprog then
                imgui.Dummy({ 0.0, 4.0 })
            end

            if settings.show_text then
                imgui.TextColored({ 0.90, 0.90, 0.90, 1.00 }, 'Ranged')
                imgui.SameLine()
                local time_str = string.format('   %.1fs', ranged.est or 5.0)
                imgui.TextColored({ 0.35, 0.75, 1.00, 1.00 }, time_str)
            end

            imgui.PushStyleColor(ImGuiCol_PlotHistogram, { 0.25, 0.70, 0.95, 1.00 })
            imgui.ProgressBar(rprog, { settings.width, settings.height }, '')
            imgui.PopStyleColor(1)
        end
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
    local sub_cmd = args[2] and args[2]:lower() or ''

    if sub_cmd == 'pos' then
        local x = tonumber(args[3])
        local y = tonumber(args[4])
        if x and y then
            settings.x = x
            settings.y = y
            reposition_pending = true
            print(string.format('[SwingBar] 座標を X:%d, Y:%d に設定しました。', x, y))
        else
            print('[SwingBar] 使用法: /sb pos <x> <y>')
        end
    elseif sub_cmd == 'text' then
        settings.show_text = not settings.show_text
        print('[SwingBar] テキスト表示: ' .. (settings.show_text and 'ON' or 'OFF'))
    elseif sub_cmd == 'melee' then
        settings.show_melee = not settings.show_melee
        print('[SwingBar] 近接バー: ' .. (settings.show_melee and 'ON' or 'OFF'))
    elseif sub_cmd == 'ranged' then
        settings.show_ranged = not settings.show_ranged
        print('[SwingBar] 遠隔バー: ' .. (settings.show_ranged and 'ON' or 'OFF'))
    else
        print('[SwingBar] コマンド一覧:')
        print('  /sb pos <x> <y> - 指定した座標へ移動')
        print('  /sb text        - 秒数テキストの表示切り替え')
        print('  /sb melee       - 近接バーの有効/無効')
        print('  /sb ranged      - 遠隔バーの有効/無効')
    end
end)