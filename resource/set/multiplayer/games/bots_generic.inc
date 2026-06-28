; AI economy tuning for RobZ 1.30.x
; Overrides RobZ bots_generic.inc. Must load AFTER RobZ.
; Currently matches RobZ stock values (no boost) as a safe baseline.
; Raise {payback N} per tier to make the bot rebuild faster after losses.
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
