--[[
MDFX_PetAnimalGuard — 撫摸動作在 server 端解析不到動物時的防護

【缺陷】
MP 下 client 發起撫摸，server 以 NetTimedAction.parse（NetTimedAction.java:142-171）
重建 action：`ISPetAnimal.new(character, animal)` 的 animal 參數由序列化的物件
id 解析，動物已死亡／已卸載／離開同步範圍時解析結果是 nil。new() 只做欄位
賦值所以照樣成功，serverStart()（ISPetAnimal.lua:81-84）也不碰 self.animal，
只註冊 3 秒後的 `pettingFinished` 模擬事件（emulateAnimEventOnce →
AnimEventEmulator）。3 秒到，animEvent（:86-93）在 :88 對 nil 解參考：

    self.animal:petAnimal(self.character);

Kahlua 拋 `attempted index: petAnimal of non-table: null`（正式服 log 實據）。
之後 timeout → perform → complete()（:69-72）同一行還會再炸一次。

vanilla 自己知道這個形狀該怎麼防——隔壁檔 ISLoadBulletsInMagazine:serverStart()
（:70-73）就有一模一樣的 guard：

    if not self.magazine then self.netAction:forceComplete() return end

ISPetAnimal 少寫了這一段。

【後果】
撫摸加成沒生效（動物都沒了，本來就給不了），但 server 留下髒例外堆疊；
頻率約 1 次/輪，三條收錄項中影響最小、修法也最單純。

【本補丁】
比照 vanilla 自家慣例，包裝三個 method（class 表替換；PZ fork 的
KahluaTableImpl.rawget 會走 metatable 鏈——KahluaTableImpl.java:98——所以
Java 端的 serverStart／complete／animEvent 派發都會拿到包裝後的版本）：

- serverStart：self.animal 為 nil → 印一次診斷、`netAction:forceComplete()`、
  不註冊模擬事件（主閘，比照 ISLoadBulletsInMagazine:70-73）。
- animEvent：nil 且 event 是 pettingFinished → 靜默略過（第二道保險；
  其他 event 原樣透傳，未來 vanilla 新增的行為照常暴露）。
- complete：nil → 回 false（比照 ISButcherAnimal:complete 對
  「屍體被別人撿走」的 vanilla 先例，ISButcherAnimal.lua:51-53）。
  Java 端 NetTimedAction.perform 把 false 傳回 ActionManager（:64），
  action 走 Reject 流程通知 client 移除——比回 true 更正確。

動物還活著的正常撫摸三個 method 全部原樣透傳，零行為差異。
放 server/ 目錄：單人與 MP 客戶端的 self.animal 是 new() 當下的本地物件
引用，不會是 nil，這個形狀只存在於 server 端的封包重建。

【安裝機制】
sentinel 存 serverStart wrapper 引用（三個 method 同批安裝、同批判斷）：
Core.ResetLua 重載時 vanilla 重建表、本檔重跑重新包裝；後載 MOD 整支替換時
OnGameBoot 復查把「他的版本」當新 original 再包一層。
比本補丁更晚的替換不在保證範圍。

【退場條件】
官方在 ISPetAnimal:serverStart 補上與 ISLoadBulletsInMagazine 同款的 nil guard。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

local warnedNilAnimal = false
local warnedNotInstalled = false

local function install()
    if type(ISPetAnimal) ~= "table"
        or type(ISPetAnimal.serverStart) ~= "function"
        or type(ISPetAnimal.animEvent) ~= "function"
        or type(ISPetAnimal.complete) ~= "function" then
        if not warnedNotInstalled then
            warnedNotInstalled = true
            print("[MinidoracatFixes] MDFX_PetAnimalGuard NOT installed: vanilla ISPetAnimal shape changed; re-check docs/fixes.md")
        end
        return
    end
    if ISPetAnimal.MDFX_petAnimalGuard == ISPetAnimal.serverStart then
        return
    end

    local originalServerStart = ISPetAnimal.serverStart
    local originalAnimEvent = ISPetAnimal.animEvent
    local originalComplete = ISPetAnimal.complete

    local function wrappedServerStart(self)
        if not self.animal then
            if not warnedNilAnimal then
                warnedNilAnimal = true
                print("[MinidoracatFixes] ISPetAnimal.serverStart: animal resolved to nil (died/unloaded); completing action instead of crashing at ISPetAnimal.lua:88. Further occurrences suppressed this session. See docs/fixes.md MDFX_PetAnimalGuard")
            end
            if self.netAction then
                self.netAction:forceComplete()
            end
            return
        end
        return originalServerStart(self)
    end

    ISPetAnimal.serverStart = wrappedServerStart

    ISPetAnimal.animEvent = function(self, event, parameter)
        if not self.animal and event == "pettingFinished" then
            return
        end
        return originalAnimEvent(self, event, parameter)
    end

    ISPetAnimal.complete = function(self)
        if not self.animal then
            return false
        end
        return originalComplete(self)
    end

    ISPetAnimal.MDFX_petAnimalGuard = wrappedServerStart
end

install()
if Events and Events.OnGameBoot then
    Events.OnGameBoot.Add(install)
end
