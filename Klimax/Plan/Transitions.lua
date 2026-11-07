-- Zone transitions (phase 21, plan s4.3 step 4): the cheapest way from one zone to another over the
-- compiled travel graph (Klimax/World/Travel.lua): zone borders on foot, boats and zeppelins, and
-- flights between zones that both have a flight master. Pure; mirrored in pipeline/sim/planner.py.
local _, K = ...
K.Plan = K.Plan or {}

local Tr = {}
K.Plan.Transitions = Tr

-- Adjacency list {[map] = {{to, cost, via, x, y}, ...}} for a travel table and weights. Edges are
-- sorted (to, via) so the search is deterministic.
function Tr.Graph(travel, wt)
    local g = {}
    local function add(a, b, cost, via, x, y)
        g[a] = g[a] or {}
        g[a][#g[a] + 1] = { to = b, cost = cost, via = via, x = x, y = y }
    end
    local border = (travel.cost and travel.cost.zoneBorder or 0) + wt.hop
    for _, pair in ipairs(travel.adj or {}) do
        add(pair[1], pair[2], border, "walk")
        add(pair[2], pair[1], border, "walk")
    end
    for _, link in ipairs(travel.links or {}) do
        local cost = (travel.cost and travel.cost[link.k]) or wt.flight
        add(link.m, link.to, cost, link.k, link.x, link.y)
    end
    -- flights: one node per zone is enough for the cost (the first by node id)
    local nodeIds = {}
    for id in pairs(travel.nodes or {}) do
        nodeIds[#nodeIds + 1] = id
    end
    table.sort(nodeIds)
    local byMap = {}
    local maps = {}
    for _, id in ipairs(nodeIds) do
        local n = travel.nodes[id]
        if not byMap[n.m] then
            byMap[n.m] = n
            maps[#maps + 1] = n.m
        end
    end
    table.sort(maps)
    for _, a in ipairs(maps) do
        for _, b in ipairs(maps) do
            if a ~= b then
                add(a, b, wt.flight, "flight", byMap[a].x, byMap[a].y)
            end
        end
    end
    for _, edges in pairs(g) do
        table.sort(edges, function(p, q)
            if p.to ~= q.to then
                return p.to < q.to
            end
            return p.via < q.via
        end)
    end
    return g
end

-- Cheapest path from map a to map b: cost and the first edge ({to, via, x, y}), or nil when b
-- cannot be reached. Dijkstra over a small graph; ties go to the lower map id.
function Tr.Path(g, a, b)
    if a == b then
        return 0, nil
    end
    local dist, first, done = { [a] = 0 }, {}, {}
    while true do
        local best, bestD
        for m, d in pairs(dist) do
            if not done[m] and (not bestD or d < bestD or (d == bestD and m < best)) then
                best, bestD = m, d
            end
        end
        if not best then
            return nil
        end
        if best == b then
            return bestD, first[b]
        end
        done[best] = true
        for _, e in ipairs(g[best] or {}) do
            local nd = bestD + e.cost
            if not done[e.to] and (dist[e.to] == nil or nd < dist[e.to]) then
                dist[e.to] = nd
                first[e.to] = (best == a) and e or first[best]
            end
        end
    end
end

-- Memoised path lookups for one plan.
function Tr.Cache(travel, wt)
    local g = Tr.Graph(travel or {}, wt)
    local memo = {}
    return function(a, b)
        local key = a * 100000 + b
        local m = memo[key]
        if not m then
            local cost, edge = Tr.Path(g, a, b)
            m = { cost or false, edge }
            memo[key] = m
        end
        return m[1] or nil, m[2]
    end
end
