--[[
MDFX_HutchNullSlotGuard — 雞舍格位留下 null，客戶端卸載雞舍時崩潰斷線（42.21）

【缺陷】（行號為 42.21.0 反編譯快照）
42.21 的 IsoHutch.removeFromWorld（IsoHutch.java:983-990）新增一個迴圈：對 animalInside.values()
的每個值呼叫 IsoAnimal.removeFromUpdateLists()，沒有 null 檢查（42.20.4 沒有這段）。而客戶端自己的
動物同步會把 null 寫進 animalInside、從不 remove：
- NetworkPlayerAI.parse(AnimalPacket)（NetworkPlayerAI.java:370-372）先對動物目前的格 put(格, null)；
  母雞進巢箱（封包 hutchPosition -1）或換格時，舊格就留著 null。
- AnimalUpdatePacket.parse（AnimalUpdatePacket.java:192-195）先 put(封包的格, null) 再
  addAnimalInside(animal, false)；加入失敗或換到別格時同樣留下 null。

【後果】
客戶端卸載雞舍所在的 chunk——走路或開車越過 chunk 邊界（IsoChunkMap.Left/Right/Up/Down）、
傳送（IsoChunkMap.Unload）——IsoChunk.removeFromWorld 逐一移除物件（IsoChunk.java:3248-3251），
IsoHutch.removeFromWorld 對 null 呼叫 → NPE → IngameState.updateInternal 的 catch 存檔後
doDisconnect("crash")（IngameState.java:1582-1620），玩家被踢回主選單。母雞下蛋時就會留下
null（在巢箱約 350–600 個 GameTime multiplier 單位，回原格才蓋掉）；換格的 null 一直留到雞舍重新載入。
伺服器與單人不經過這兩條同步路徑。

【本補丁】
每幀在 OnTick 把已登記雞舍的 null 格拿掉。Integer key 經過 Lua 一律變成 double
（KahluaNumberConverter.java:103-116），HashMap.remove(Object) 拿 double 對不到；所以把 key 寫進
一隻暫用母雞的 hutchPosition，呼叫原版 IsoHutch.removeAnimal（IsoHutch.java:538-544：以 int 自動
裝箱 remove，客戶端不送封包）。暫用母雞在 (0,0,0) 建立、不進世界，呼叫後 hutch／hutchPosition 回到
nil／-1。格子裡有屍體時不動（removeAnimal 會一併拿掉屍體），印一行診斷。
null 與「沒有這個 key」對原版的 get() 等價；拿掉後 size() 只算真的動物（原版雞舍選單判斷「已滿」、
畜牧區介面數動物都用 size()，不再把空格算進去）。

【效能】
1. 雞舍登記不掃格子：MapObjects.OnLoadWithSprite 由 Java 依圖塊名分派（MapObjects.java:184-218），
   只有雞舍圖塊會呼叫到這裡；建造中新增的雞舍走 OnObjectAdded（AddItemToMapPacket.java:94）。
   登記的是封包解析時拿到的那一座（IsoHutch.getHutch＝主雞舍格上第一個 IsoHutch）。
2. 第一座雞舍登記後才掛 OnTick；單人與附近沒有雞舍的客戶端零成本。
3. 每幀每座雞舍一次 HashMap.containsValue(null)；有 null 時才取 key 清單。
4. 每 PRUNE_EVERY 幀放掉已卸載或已移除的雞舍（chunk 卸載時格子的 chunk 設成 null，IsoChunk.java:3260）。

【已知限制】
GameClient.update 在 IngameState.updateInternal 之前、OnTick 在之後（GameWindow.java:284-363）：
同一幀內剛寫進 null 又剛好卸載那座雞舍時，仍走原版崩潰路徑。null 格裡有屍體時不清。

【退場條件】
官方在 IsoHutch.removeFromWorld 略過 null，或客戶端同步改成 remove 舊格、不再 put null。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`（本修復登記的是 Java 指紋）。
]]

if MDFX_HutchNullSlotGuard then return end

local warned = {}
local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print("[MinidoracatFixes] MDFX_HutchNullSlotGuard " .. message .. " See docs/fixes.md MDFX_HutchNullSlotGuard")
end

if not (Events and Events.OnTick and Events.OnTick.Add and Events.OnObjectAdded and Events.OnObjectAdded.Add
        and MapObjects and MapObjects.OnLoadWithSprite and HutchDefinitions and type(HutchDefinitions.hutchs) == "table"
        and ArrayList and ArrayList.new and addAnimal and getCell and isClient and instanceof
        and AnimalDefinitions and AnimalDefinitions.getDef) then
    warnOnce("shape", "NOT installed: engine API shape changed; re-check docs/fixes.md.")
    return
end

local PRIORITY = 7134   -- MapObjects 同圖塊同 priority 會覆蓋先前的登記（MapObjects.java:148-151），取一個少見的值
local PRUNE_EVERY = 300 -- 幀
local QUIET = 300       -- 只剩有屍體的 null 格時，這座雞舍隔幾幀再看

-- 已登記的雞舍：陣列存雞舍、它的 animalInside、冷卻幀數；index 由雞舍查陣列位置
local hutches, maps, quiet, index = {}, {}, {}, {}
local G = { removed = 0, skipped = 0, purges = 0 }
G.tracked = function() return #hutches end
MDFX_HutchNullSlotGuard = G

local mp = nil
local disabled = false
local ticking = false
local frame = 0
local keys = nil
local scratch = nil
local onTick

local function disable(err)
    disabled = true
    warnOnce("error", "disabled for this session after an unexpected error: " .. tostring(err) .. ".")
end

local function add(h)
    if index[h] then return end
    local n = #hutches + 1
    hutches[n], maps[n], quiet[n] = h, h:getAnimalInside(), 0
    index[h] = n
    if not ticking then
        ticking = true
        Events.OnTick.Add(onTick)
    end
end

local function track(obj)
    if obj:isSlave() then return end
    add(obj)
    local sq = obj:getSquare()
    local first = sq and sq:getHutch()
    if first and first ~= obj then add(first) end
end

local function onHutch(obj)
    if disabled then return end
    if mp == nil then mp = isClient() == true end
    if not mp or not instanceof(obj, "IsoHutch") then return end
    local ok, err = pcall(track, obj)
    if not ok then disable(err) end
end

local function untrack(i)
    local n = #hutches
    index[hutches[i]] = nil
    if i ~= n then
        hutches[i], maps[i], quiet[i] = hutches[n], maps[n], quiet[n]
        index[hutches[i]] = i
    end
    hutches[n], maps[n], quiet[n] = nil, nil, nil
end

local function where(h)
    return h:getX() .. "," .. h:getY() .. "," .. h:getZ()
end

local function scratchHen()
    if scratch == nil then
        local def = AnimalDefinitions.getDef("hen")
        scratch = addAnimal(getCell(), 0, 0, 0, "hen", def and def:getBreedByName("rhodeisland"))
    end
    return scratch
end

local function purge(i)
    local h, map = hutches[i], maps[i]
    G.purges = G.purges + 1
    local before = map:size()
    keys = keys or ArrayList.new()
    keys:clear()
    keys:addAll(map:keySet())
    for j = 0, keys:size() - 1 do
        local k = keys:get(j)
        if h:getAnimal(k) == nil then
            if h:getDeadBody(k) ~= nil then
                G.skipped = G.skipped + 1
                warnOnce("body", "left null slot " .. k .. " of the hen house at " .. where(h)
                    .. " untouched: it also holds a dead body.")
            else
                local s = scratchHen()
                s:getData():setHutchPosition(k)
                h:removeAnimal(s)
            end
        end
    end
    keys:clear()
    -- 留下的 null（有屍體、或不是 Integer 的 key）隔 QUIET 幀再看，不每幀重跑
    if map:containsValue(nil) then quiet[i] = QUIET end
    local removed = before - map:size()
    if removed <= 0 then return end
    G.removed = G.removed + removed
    warnOnce("removed", "removed null slot(s) from the hen house at " .. where(h)
        .. " (vanilla would crash and disconnect when its chunk unloads). Further removals not logged this session.")
end

local function tick()
    for i = 1, #hutches do
        local q = quiet[i]
        if q > 0 then
            quiet[i] = q - 1
        elseif maps[i]:containsValue(nil) then
            purge(i)
        end
    end
    frame = frame + 1
    if frame >= PRUNE_EVERY then
        frame = 0
        for i = #hutches, 1, -1 do
            local h = hutches[i]
            local sq = h:getSquare()
            if sq == nil or sq:getChunk() == nil or h:getObjectIndex() < 0 then untrack(i) end
        end
    end
end
G.tick = tick

onTick = function()
    if disabled then return end
    local ok, err = pcall(tick)
    if not ok then disable(err) end
end

local sprites, seen = {}, {}
local function sprite(name)
    if type(name) == "string" and name ~= "" and not seen[name] then
        seen[name] = true
        sprites[#sprites + 1] = name
    end
end
for _, def in pairs(HutchDefinitions.hutchs) do
    if type(def) == "table" then
        sprite(def.baseSprite)
        for _, part in ipairs(type(def.extraSprites) == "table" and def.extraSprites or {}) do
            sprite(part.sprite)
            sprite(part.spriteOpen)
        end
        for _, door in ipairs(type(def.eggHatchDoors) == "table" and def.eggHatchDoors or {}) do
            sprite(door.sprite)
            sprite(door.closedSprite)
        end
    end
end
if #sprites == 0 then
    warnOnce("shape", "NOT installed: HutchDefinitions has no sprites; re-check docs/fixes.md.")
    return
end

MapObjects.OnLoadWithSprite(sprites, onHutch, PRIORITY)
Events.OnObjectAdded.Add(onHutch)
