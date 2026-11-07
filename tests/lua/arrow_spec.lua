-- Arrow geometry and read-out (phase 07, PRD 7.5). Positions are stubbed: the player stands at
-- map 1 (0.5, 0.5), which is world (500, 500) yards, on continent 1. Map percent times 1000 gives yards.
package.path = "tests/lua/?.lua;" .. package.path
local W = require("wowstubs")

local function near(expected, actual, tol)
    assert.is_true(math.abs(expected - actual) <= (tol or 1e-6), ("expected %s, got %s"):format(expected, actual))
end

describe("arrow geometry", function()
    local A
    setup(function()
        W.start({ skipRoutes = true })
        A = W.K.Arrow
    end)

    it("a target straight north of the player, facing north, is straight ahead", function()
        local r = A.Compute({ cont = 1, x = 0, y = 0 }, { cont = 1, x = 0, y = 100 }, 0)
        assert.equals("arrow", r.kind)
        near(0, r.rot)
        near(100, r.dist)
    end)

    it("a target to the west (left when facing north) gives a positive quarter turn", function()
        local r = A.Compute({ cont = 1, x = 0, y = 0 }, { cont = 1, x = -100, y = 0 }, 0)
        near(math.pi / 2, r.rot)
    end)

    it("a target to the east (right when facing north) gives a negative quarter turn", function()
        local r = A.Compute({ cont = 1, x = 0, y = 0 }, { cont = 1, x = 100, y = 0 }, 0)
        near(-math.pi / 2, r.rot)
    end)

    it("turning towards the target brings the arrow straight ahead", function()
        -- The target is west. Facing west (pi/2) puts it straight ahead.
        local r = A.Compute({ cont = 1, x = 0, y = 0 }, { cont = 1, x = -100, y = 0 }, math.pi / 2)
        near(0, r.rot)
    end)

    it("the relative angle always lies in (-pi, pi]", function()
        for facing = -4 * math.pi, 4 * math.pi, 0.37 do
            local r = A.Compute({ cont = 1, x = 0, y = 0 }, { cont = 1, x = 30, y = -70 }, facing)
            assert.is_true(r.rot > -math.pi - 1e-9 and r.rot <= math.pi + 1e-9, tostring(r.rot))
        end
    end)

    it("distance is the straight-line distance in yards", function()
        local r = A.Compute({ cont = 1, x = 500, y = 500 }, { cont = 1, x = 100, y = 100 }, 0)
        near(400 * math.sqrt(2), r.dist, 1e-6)
    end)

    it("different continents give the travel state, not an angle", function()
        local r = A.Compute({ cont = 1, x = 0, y = 0 }, { cont = 2, x = 5, y = 5 }, 0)
        assert.equals("travel", r.kind)
        assert.is_nil(r.rot)
    end)
end)

describe("arrow read-out", function()
    local function demoRoute(z)
        W.registerRoute({ id = "arrow_route", faction = "horde", branch = "horde", lo = 1, hi = 5,
            entry = { z = z, x = 1, y = 1, lv = 1 },
            steps = { { t = "A", k = "AR1", q = 101, n = "Arrow quest", g = "m", z = z, x = 10, y = 10, npc = 500 } } })
    end

    local function started(zone)
        local K = W.start({ skipRoutes = true })
        demoRoute(zone or 1413)
        W.fire("PLAYER_LOGIN")
        return K
    end

    it("points at the displayed step with the distance from the stubbed positions", function()
        local K = started()
        assert.equals("arrow_route", K.Engine.routeId)
        local r = K.Arrow.Read()
        assert.equals("arrow", r.kind)
        -- Player (500, 500); target percent (10, 10) gives world (100, 100). dx = dy = -400.
        near(400 * math.sqrt(2), r.dist, 1e-6)
        -- Bearing atan2(400, -400) = 3pi/4 measured from north, facing 0.
        near(3 * math.pi / 4, r.rot, 1e-6)
    end)

    it("turning changes the relative angle by the same amount", function()
        local K = started()
        local before = K.Arrow.Read().rot
        W.state.facing = 0.5
        local after = K.Arrow.Read().rot
        near(-0.5, after - before, 1e-6)
    end)

    it("shows the travel state when the target is on another continent", function()
        local K = started(1413)
        W.state.contOf[1413] = 2
        local r = K.Arrow.Read()
        assert.equals("travel", r.kind)
        assert.equals("The Barrens", r.zone)
    end)

    it("is hidden when there is no player map position (instances)", function()
        local K = started()
        W.state.mapID = nil
        assert.equals("hidden", K.Arrow.Read().kind)
    end)

    it("is hidden when the arrow option is off", function()
        local K = started()
        K.SetOption("arrow", false)
        assert.equals("hidden", K.Arrow.Read().kind)
    end)

    it("is hidden while the main window is hidden or in combat", function()
        local K = started()
        K.Arrow.allowed = false
        assert.equals("hidden", K.Arrow.Read().kind)
        K.Arrow.allowed = true
    end)

    it("is hidden when no route is loaded", function()
        local K = W.start({ skipRoutes = true })
        assert.equals("hidden", K.Arrow.Read().kind)
    end)
end)
