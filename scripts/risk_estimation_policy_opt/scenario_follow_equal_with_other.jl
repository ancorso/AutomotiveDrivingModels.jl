scenario = let

    sn = generate_straight_nlane_streetmap(2)

    speed_65mph = 29.06

    lanetagL = get_lanetag(0.0,0.0,sn)
    lanetagR = get_lanetag(0.0,-5.0,sn)

    history     = 4*DEFAULT_FRAME_PER_SEC # [pdset frames]
    horizon     = 4*DEFAULT_FRAME_PER_SEC # [pdset frames]
    x₀          = 10.5 # [m]
    delta_speed = 0.93 # [%]
    delta_x     = 20.0 # [m]

    trajs = Array(TrajDef, 3)
    trajs[1] = TrajDef(sn, VecE2(x₀,-4.5), speed_65mph)
    push!(trajs[1], TrajDefLinkTargetSpeed(history, lanetagR, 0.0, speed_65mph))
    push!(trajs[1], TrajDefLinkTargetSpeed(horizon*4, lanetagR, 0.0, speed_65mph))

    trajs[2] = TrajDef(sn, VecE2(x₀+delta_x,-4.5), delta_speed*speed_65mph)
    push!(trajs[2], TrajDefLinkTargetSpeed(history, lanetagR, 0.0, delta_speed*speed_65mph))
    push!(trajs[2], TrajDefLinkTargetSpeed(horizon*4, lanetagR, 0.0, delta_speed*speed_65mph))

    trajs[3] = TrajDef(sn, VecE2(x₀-10,-1.5), speed_65mph)
    push!(trajs[3], TrajDefLinkTargetSpeed(history, lanetagL, 0.0, speed_65mph))
    push!(trajs[3], TrajDefLinkTargetSpeed(horizon*4, lanetagL, 0.0, speed_65mph))

    Scenario("three_car", sn, history, DEFAULT_SEC_PER_FRAME, trajs)
end