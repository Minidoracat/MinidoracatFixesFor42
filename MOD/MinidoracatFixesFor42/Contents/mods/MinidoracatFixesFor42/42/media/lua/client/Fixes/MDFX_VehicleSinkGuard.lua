--[[
MDFX_VehicleSinkGuard — 多人遊戲開車時車掉到地板下：畫面全黑，下車後車陷在地下，重登也一樣

【缺陷】（行號為 42.22.2 反編譯快照）
多人遊戲裡，車的物理只在駕駛（或開車撞到它的人）的客戶端算，伺服器照收客戶端回報的
高度。原生物理在一次碰撞、或車被拉到地面碰撞體還沒建好的地方時，可能把車推到地板下。
BaseVehicle.update()（BaseVehicle.java:3402-3410）只用物理高度推算樓層，不把車放回
地板以上；原版只有從存檔載入時（BaseVehicle.load，:2738-2740）把高度夾在樓層地板以上。

【後果】
坐在車上時鏡頭跟著車的物理高度，原點在地板下就全黑、只剩 HUD；車一路往下掉，
伺服器也照那個高度存檔，下車後車陷在地下，重新登入拿到的還是地下的車。

【本補丁】
多人客戶端每一幀（OnTick，在所有車的 update 之後）看本機正在模擬的車
（isLocalPhysicSim：自己開的、自己開車撞到的）。物理原點比所在樓層地板低 SINK_DEPTH
以上、而且那一格有地板，就用原版 setWorldTransform（原生 teleportVehicle，會清掉
速度）把車放回停放高度，水平位置與方向不變。翻覆的車（getUpVectorDot 低於
BaseVehicle.MINIMUM_DOT_UPRIGHT）要低於地板一層以上才處理，放回前先用原版 setAngles
扶正、保留車頭方向；翻覆而只低一點的車（車頂著地、翻在溝裡）照原版。
放回高度照原版 CarController 生成車輛的算法：−min(模型偏移＋第一個輪子偏移－輪半徑,
重心偏移－車身高÷2)，至少 MIN_REST。Lua 讀不到輪半徑（VehicleScript.Wheel.radius 是
沒有 getter 的欄位），改用 WHEEL_RADIUS（該欄位的預設值，比多數車的輪子大）：車放在
略高於停放高度的地方，自己落回地面。本機下一則車輛物理封包就把地面上的高度送給伺服器。
有駕駛而靜止滿 1 秒的車，原版會停掉它的物理（CarController.checkShouldBeActive），原生
teleportVehicle 對這種車不生效、下一幀讀回的還是地板下的姿勢；所以放回前先 setPhysicsActive(true)。

判定條件和 MinidoracatJavaPatchFor42 的客戶端修補 W65 相同，放回高度只差上面那一點。
裝了那個修補包的玩家，W65 在車的 update 裡先處理，本補丁在同一幀稍後看到的高度已經
正常，不會再介入。

【已知限制】
- 不處理車為什麼掉下去；只在掉下去之後放回。
- 原點在地板下、那一格卻沒有地板的車照原版。
- 已經陷在地下、沒有人在開的車不處理（伺服器重新從存檔載入那台車時原版會夾回）。
- 單人遊戲的車不由客戶端授權模擬（isLocalPhysicSim 恆為 false），本補丁不啟用。

【診斷】
每次介入記一行（每次啟動最多 LOG_LIMIT 行，之後照樣放回、不再記）。

【退場條件】
官方在 BaseVehicle.update() 把掉到地板下的車放回地面，或伺服器收高度時夾樓層。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`（本修復登記的是 Java 指紋）。
]]

if MDFX_VehicleSinkGuard then return end

local function say(message)
    print("[MinidoracatFixes] MDFX_VehicleSinkGuard " .. message .. " See docs/fixes.md MDFX_VehicleSinkGuard")
end

if not (Events and Events.OnTick and Events.OnTick.Add and isClient and getCell and getSquare
        and ArrayList and ArrayList.new and Transform and Transform.new and Vector3f and Vector3f.new) then
    say("NOT installed: engine API shape changed; re-check docs/fixes.md.")
    return
end

local LEVEL_HEIGHT = 2.44949 -- 一層樓的物理高度（BaseVehicle.update 與 load）
local SINK_DEPTH = 0.25      -- 原點比地板低多少才算掉下去；車頭著地的拖車約 0.1
local MIN_UPRIGHT = 0.8      -- BaseVehicle.MINIMUM_DOT_UPRIGHT
local MIN_REST = 0.1
-- ponytail: Lua 讀不到 VehicleScript.Wheel.radius（Kahlua 只曝露 public static 欄位），用它的預設值當上限；
-- 輪子更大的車會放低一點、由懸吊頂回去。官方替 Wheel 加 getRadius 之後改讀實際值。
local WHEEL_RADIUS = 0.5
local LOG_LIMIT = 20

local floor, max, min, deg, atan2 = math.floor, math.max, math.min, math.deg, math.atan2
local getSquare = getSquare

local G = { lifted = 0, righted = 0 }
MDFX_VehicleSinkGuard = G

local list = ArrayList.new()
local xfrm = Transform.new()
local vec = Vector3f.new()
local disabled = false

-- 放回時物理原點比樓層地板高多少
local function restHeight(script)
    local wheelBottom = 0
    if script:getWheelCount() > 0 then
        local offset = script:getModelOffset()
        wheelBottom = (offset and offset:y() or 0) + script:getWheel(0):getOffset():y() - WHEEL_RADIUS
    end
    local rest = -min(wheelBottom, script:getCenterOfMassOffset():y() - script:getExtents():y() / 2)
    return max(rest, MIN_REST)
end

-- 該放回時回傳：放回高度、目前物理高度、樓層、朝上程度；其餘回 nil（不動）
local function target(v)
    local script = v:getScript()
    if not script then return nil end
    local level = floor(v:getZ())
    local floorY = level * LEVEL_HEIGHT
    local y = v:getWorldTransform(xfrm):getOrigin():y()
    if not (y < floorY - SINK_DEPTH) then return nil end
    local up = v:getUpVectorDot()
    if up < MIN_UPRIGHT and not (y < floorY - LEVEL_HEIGHT) then return nil end
    local sq = getSquare(floor(v:getX()), floor(v:getY()), level)
    if not sq or not sq:hasFloor() then return nil end
    return floorY + restHeight(script), y, level, up
end

local function place(v, to, y, level, up)
    local auth = tostring(v:getAuthorizationDescription()) -- 診斷行記啟用物理之前的狀態
    v:setPhysicsActive(true) -- 物理停掉的車 teleportVehicle 不生效（見檔頭）
    local flipped = up < MIN_UPRIGHT
    if flipped then
        -- 扶正並保留車頭方向：前向量的水平分量決定繞 Y 軸的角度
        local f = v:getForwardVector(vec)
        v:setAngles(0, deg(atan2(f:x(), f:z())), 0)
        G.righted = G.righted + 1
    end
    local o = v:getWorldTransform(xfrm):getOrigin()
    o:set(o:x(), to, o:z())
    v:setWorldTransform(xfrm)
    G.lifted = G.lifted + 1
    if G.lifted <= LOG_LIMIT then
        say(string.format("vehicle %s %s at %.2f,%.2f (%s): physics height %.3f is below the floor of level %d; %slifted to %.3f (#%d%s).",
            tostring(v:getId()), tostring(v:getScriptName()), v:getX(), v:getY(), auth,
            y, level, flipped and string.format("flipped (up %.3f), set upright keeping its heading, ", up) or "",
            to, G.lifted, G.lifted == LOG_LIMIT and ", further events are not logged" or ""))
    end
end

local function tick()
    if not isClient() then return end
    local cell = getCell()
    if not cell then return end
    list:addAll(cell:getVehicles())
    for i = 0, list:size() - 1 do
        local v = list:get(i)
        if v:isLocalPhysicSim() then
            local to, y, level, up = target(v)
            if to then place(v, to, y, level, up) end
        end
    end
    list:clear()
end
G.tick = tick

local function onTick()
    if disabled then return end
    local ok, err = pcall(tick)
    if not ok then
        disabled = true
        list = nil
        say("disabled after an internal error (vanilla behaviour from here on): " .. tostring(err) .. ".")
    end
end

Events.OnTick.Add(onTick)
