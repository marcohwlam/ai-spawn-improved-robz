; AI economy tuning for RobZ 1.30.x
; Overrides RobZ bots_generic.inc. Must load AFTER RobZ.
; balancingFactorBonus applies to the trailing (losing) side: mp = manpower multiplier when
; behind, payback = how fast losses are refunded, cp = command points. Raise mp/payback to let
; a losing bot recover harder. These semantics are inferred from preset usage; the engine ships
; no documentation for these keys and the stock file carries no comments.
; Concurrent unit count is still bounded by MaxLiveSquads in bot.lua, so extra MP buys pricier
; units / faster refill, not an unbounded army.
; hard keeps RobZ stock values (mp 2.0, payback 4.0) so every tier holds a distinct
; (mp, payback) pair. A previous revision raised hard to heroic's 3.0/8.0, which made the two
; tiers economically identical.
{easy
	{balancingFactorBonus {cp 1.00} {mp 0.75} {payback 1.00} }
	{chargeFactors
		{value "*=1.0"}
	}
}
{normal
	{balancingFactorBonus {cp 1.00} {mp 1.00} {payback 2.00} }
	{chargeFactors
		{value "*=1.0"}
	}
}
{hard
	{balancingFactorBonus {cp 1.50} {mp 2.00} {payback 4.00} }
	{chargeFactors
		{value "*=1.0"}
	}
}
{heroic
	{balancingFactorBonus {cp 1.50} {mp 3.00} {payback 8.00} }
	{chargeFactors
		{value "*=1.0"}
	}
}
