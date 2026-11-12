--[[
MDFX_ConsumedContainerGuard — 配方把裝著東西的容器物品當材料用掉時，留下它裡面剩的東西（伺服器與單人）

【缺陷】（行號為 42.22.2 原版腳本、原版 Lua 與反編譯快照）
配方的輸入行要有 `IsEmpty` 旗標，引擎才擋掉裝著東西的容器物品（InputScript.java:1040）。原版有 8 行漏了：
圓形與方形集雨桶的「垃圾袋 4」（generated/entities/outdoors/entity_raincollector.txt:43、:98；別的垃圾袋配方 11 行都有）、
拆麻袋 ScrapSack 與 ScrapSackLarge、CutHeadSack、MakeHollowBook、熔金／銀鑰匙圈 Scrap_Smaller_Gold_Object／_Silver_Object。
MOD 加的配方也可能漏。
完成端用掉材料時（CraftRecipeData.processDestroyAndUsedItems，CraftRecipeData.java:517-573）對容器物品呼叫
ItemUser.RemoveItem（ItemUser.java:123-180）：只把那件容器物品從它所在的容器或地上移除，它裡面的東西沒有人處理。

【後果】袋子裡不是這次材料的東西、多帶的材料、放在袋裡的工具，全部跟著袋子消失，沒有任何訊息（42.22.2 實機
E2E `bag-material`：蓋集雨桶三種擺法與拆麻袋兩種擺法都重現）。多人遊戲另有一個副作用：袋子在角色身上、
袋裡的東西也是這次材料時，伺服器印 `Unable to resolve container location`（每個連線一份）。本補丁不處理那串訊息：
它不影響結果，袋裡被用掉的材料本來就要移除。

【本補丁】包裝兩個完成端：建造的 `ISBuildIsoEntity.create`（server/BuildingObjects/ISBuildIsoEntity.lua:510-602）
與手工製作的 `ISHandcraftAction.performRecipe`（shared/Entity/TimedActions/ISHandcraftAction.lua:225-254）。
前：記下每一件裝著東西的容器物品，以及它在哪個容器、或在地上的哪一格哪個位置（判準同 ItemUser.RemoveItem）。看兩個地方：
    這次配方的容器清單（logic:getContainers()；配方只會用到這些容器的直接物品，CraftRecipeManager.java:274-282），
    與角色所在格加周圍一圈的地上物品（完成時原版會重新收集這個範圍當材料，BaseCraftingLogic.java:792-816：
    動作開始後才放到地上的袋子不在原本的清單裡）。清單裡已經不在任何地方的過期項目不記：原版完成時不會用到它。
原函式照原樣呼叫，回傳值照原樣回傳；原函式的錯原樣外洩（不 pcall 它）。
後：記下的容器物品現在既不在任何容器、也不在地上（＝被用掉了），才把它裡面剩下的東西放回它原本所在的地方：
    原本在地上就放回同一格同一個位置（先從袋子拿掉再 AddWorldInventoryItem，伺服器會送給客戶端；放不成就塞回袋裡、記失敗）；
    原本在容器裡就放回那個容器（AddItem 會先把物品從舊容器拿掉，不會多出一份；再 sendAddItemToContainer；
    放回的地方在車上（車的容器，或車上背包的內部）就照原版 ItemUser 的做法重算那個車容器的內容量）。
    原本所在的容器自己也被這次配方用掉（袋中袋）時，改放角色的主背包。
    原本所在的容器送不到客戶端（車上或箱子裡的背包的內部：GameServer.sendAddItemToContainer 與
    sendRemoveItemFromContainer 的三個分支都不成立，GameServer.java:2427-2443、:2487-2503，連原版移除袋子的封包也沒送到）時，
    照樣放回原處，再把外層那件容器物品從它所在的容器整件重送（移除再加入，這兩個封包送得到），客戶端照伺服器現在的內容重建。
    放完讀回：袋裡還有剩就印一次（Java 端出錯時 Lua 收不到錯誤）。
容器物品還在（沒被用掉）、或被用掉時已經是空的：什麼都不做。每種配方第一次介入記一行，每次開機最多 LOG_LIMIT 種。
自己的部分各自 pcall（記錄一段、每個袋子的放回各一段）：出錯印一次，原版的結果照舊，其他袋子照樣處理。

【取捨】
- 和配方是哪一個無關：只看「容器物品被用掉時裡面還有東西」。配方若是故意連內容一起銷毀（沒看過這種原版配方），
  內容也會被留下來。
- 原函式中途拋錯時「後」不會跑：那時袋子有沒有被用掉不一定，不猜。
- 只管這兩個完成端。機台自動製作（CraftLogic）由 Java 直接完成，沒有 Lua 完成端可以包。
- 放回主背包不檢查負重（使用者裁定放回原處）。原版把製作產物交給角色時會檢查，放不下就丟地上（Actions.addOrDropItem）。

【安裝機制】
放 server/：單人與伺服器都載入（排在原版 server/BuildingObjects 與所有 MOD 的 shared/ 之後），多人遊戲的客戶端不安裝
（兩個完成端的消耗都在伺服器跑）。sentinel 存 wrapper 自身引用；OnInitGlobalModData 復查（單人進場時才載 server/，
OnGameBoot 早就觸發過）：之後被別的檔整支替換時再包一層。兩個完成端各自檢查形狀，一個變了不影響另一個。

【退場條件】
官方讓配方用掉容器物品時處理它的內容（清空、掉出來或一律要求空的）。到時「後」看到的都是空袋，自動不介入
（診斷行不再出現）。遊戲更新後跑 `python scripts/check_vanilla_alignment.py`。
]]

if type(isClient) ~= "function" or isClient() then return end

local NAME = "MDFX_ConsumedContainerGuard"
local LOG_LIMIT = 20 -- 每次開機最多記幾種配方

local warned = {}
local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print("[MinidoracatFixes] " .. NAME .. " " .. message .. " See docs/fixes.md " .. NAME)
end

local function clip(v)
    return (string.sub((string.gsub(tostring(v), "[%c\"]", "?")), 1, 48))
end

local function failed(detail)
    warnOnce("error", "could not keep what a used-up container held; vanilla result kept: " .. tostring(detail) .. ".")
end

local logged = 0
local function report(action, bag, count, where)
    local recipe = action.craftRecipe
    local name = clip(recipe and recipe:getName() or "?")
    if warned["used:" .. name] then return end
    if logged >= LOG_LIMIT then
        return warnOnce("limit", "kept the contents for more than " .. LOG_LIMIT .. " recipes; not logging further recipes this session.")
    end
    logged = logged + 1
    warnOnce("used:" .. name, 'recipe="' .. name .. '" used up ' .. clip(bag:getFullType()) .. " that still held " .. count
        .. " item(s); put them back " .. where .. ". Logged once per recipe.")
end

-- 物品在地上的世界物件；已經從格子移除的不算（引用還留在物品上，同 ItemUser.RemoveItem 的判準）
local function worldItemOf(item)
    local wi = item:getWorldItem()
    if wi and wi:getWorldObjectIndex() ~= -1 then return wi end
    return nil
end

local function gone(item)
    return item:getContainer() == nil and worldItemOf(item) == nil
end

-- 照 GameServer.sendAddItemToContainer／sendRemoveItemFromContainer 的三個分支：這個容器的增減伺服器送不送得到客戶端
local function reachable(container)
    local who = container:getCharacter()
    if who and instanceof(who, "IsoPlayer") then return true end
    if container:getParent() then return true end
    local holder = container:getContainingItem()
    return holder ~= nil and worldItemOf(holder) ~= nil
end

-- container 的增減送不到客戶端（原版移除袋子時也一樣）：往外找到第一件「所在容器送得到」的容器物品，整件移除再加入，
-- 客戶端就照伺服器現在的內容重建它。外層已經不在任何地方（鏈斷了）就沒有東西可以重送
local function resend(container)
    local top = container:getContainingItem()
    for _ = 1, 16 do
        local outer = top and top:getContainer()
        if outer == nil then return end
        if reachable(outer) then
            sendRemoveItemFromContainer(outer, top)
            sendAddItemToContainer(outer, top)
            return
        end
        top = outer:getContainingItem()
    end
end

local function note(held, item)
    if not instanceof(item, "InventoryContainer") or item:getInventory():isEmpty() then return end
    local rec = { bag = item }
    local wi = worldItemOf(item)
    if wi then
        rec.sq, rec.x, rec.y, rec.z = wi:getSquare(), wi:getOffX(), wi:getOffY(), wi:getOffZ()
    else
        rec.home = item:getContainer()
        -- 清單裡的過期項目（動作開始後被別的途徑移除，已經不在任何地方）：原版完成時重建清單、不會用到它，不是這次用掉的
        if rec.home == nil then return end
    end
    held[#held + 1] = rec
end

local function snapshot(logic, character)
    local held = {}
    local containers = logic:getContainers()
    for i = 0, containers:size() - 1 do
        local items = containers:get(i):getItems()
        for j = 0, items:size() - 1 do note(held, items:get(j)) end
    end
    -- 完成時原版會重新收集角色所在格加周圍一圈的地上物品，所以要在原函式之前先記。同一件記兩次無妨：放回時第一次搬空，第二次看到空袋就返回
    local at = character:getSquare()
    if at then
        local cell = getCell()
        for x = at:getX() - 1, at:getX() + 1 do
            for y = at:getY() - 1, at:getY() + 1 do
                local sq = cell:getGridSquare(x, y, at:getZ())
                local objects = sq and sq:getWorldObjects()
                for i = 0, objects and objects:size() - 1 or -1 do
                    note(held, objects:get(i):getItem())
                end
            end
        end
    end
    return held
end

local function putBack(action, rec)
    local bag = rec.bag
    if not gone(bag) then return end
    local inv = bag:getInventory()
    if inv:isEmpty() then return end -- 裡面的東西都被這次配方用掉了：沒有要放回的
    -- 原本所在的容器自己也被這次配方用掉了（袋中袋）：改放角色的主背包。原本在地上的用不到 home
    local home = rec.home
    local outer = home and home:getContainingItem()
    if home == nil or (outer and gone(outer)) then home = action.character:getInventory() end
    local where = rec.sq and "on its square" or home == rec.home and "in the container it was in" or "in the player's main inventory"
    local items = inv:getItems()
    local count = items:size()
    for j = count - 1, 0, -1 do
        local item = items:get(j)
        if rec.sq then
            inv:Remove(item)
            -- Java 端出錯時回 nil。物品還沒落地才塞回袋裡（算沒搬走，下面讀回時記失敗）；已經落地就留在地上
            if not rec.sq:AddWorldInventoryItem(item, rec.x, rec.y, rec.z) and worldItemOf(item) == nil then inv:AddItem(item) end
        else
            home:AddItem(item)
            sendAddItemToContainer(home, item)
        end
    end
    if not reachable(home) then resend(home) end
    -- 車上的容器（含車上背包的內部：看最外層）：內容量與車重照原版加減物品後的做法重算（ItemUser.java:116-118）。
    -- 客戶端收到重送的封包時也會重算，伺服器不算兩端就不一樣
    local part = home:getOutermostContainer():getVehiclePart()
    if part then part:setContainerContentAmount(part:getItemContainer():getCapacityWeight()) end
    -- Java 端拋例外時 Lua 只拿到 nil，要讀回才知道有沒有搬走
    local left = inv:getItems():size()
    if left > 0 then failed(left .. " item(s) are still inside a used-up " .. clip(bag:getFullType())) end
    if left < count then report(action, bag, count - left, where) end
end

local function wrap(cls, className, method, logicKey)
    if type(cls) ~= "table" or type(cls[method]) ~= "function" then
        warnOnce("shape:" .. className, "NOT installed: vanilla " .. className .. " shape changed; re-check docs/fixes.md.")
        return
    end
    if cls[NAME] == cls[method] then return end

    local original = cls[method]

    local function wrapper(self, ...)
        local logic, ok, held = self[logicKey], false, nil
        if logic then
            ok, held = pcall(snapshot, logic, self.character)
            if not ok then failed(held) end
        end
        local result = original(self, ...)
        if ok then
            -- 一個袋子一段：其中一個出錯，其餘的照樣放回
            for i = 1, #held do
                local done, err = pcall(putBack, self, held[i])
                if not done then failed(err) end
            end
        end
        return result
    end

    cls[method] = wrapper
    cls[NAME] = wrapper
end

local function install()
    if not (type(instanceof) == "function" and type(sendAddItemToContainer) == "function"
            and type(sendRemoveItemFromContainer) == "function" and type(getCell) == "function") then
        warnOnce("api", "NOT installed: engine API shape changed; re-check docs/fixes.md.")
        return
    end
    wrap(ISBuildIsoEntity, "ISBuildIsoEntity", "create", "buildPanelLogic")
    wrap(ISHandcraftAction, "ISHandcraftAction", "performRecipe", "logic")
end

install()
if Events and Events.OnInitGlobalModData then
    Events.OnInitGlobalModData.Add(install)
end
