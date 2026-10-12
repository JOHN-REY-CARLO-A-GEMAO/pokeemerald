EventScript_RepelWoreOff::
	msgbox Text_RepelWoreOff, MSGBOX_SIGN
	special Special_GetRepelToReuse
	goto_if_eq VAR_RESULT, ITEM_NONE, EventScript_RepelWoreOff_End
	msgbox Text_UseAnotherRepel, MSGBOX_YESNO
	goto_if_eq VAR_RESULT, NO, EventScript_RepelWoreOff_End
	special Special_UseRepelToReuse
	msgbox Text_PlayerUsedAnotherRepel, MSGBOX_DEFAULT
EventScript_RepelWoreOff_End::
	end

Text_RepelWoreOff:
	.string "REPEL's effect wore off…$"

Text_UseAnotherRepel:
	.string "Would you like to use another\n{STR_VAR_1}?$"

Text_PlayerUsedAnotherRepel:
	.string "{PLAYER} used another\n{STR_VAR_1}!$"
