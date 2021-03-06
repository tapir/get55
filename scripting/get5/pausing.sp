public bool Pauseable() {
  return g_GameState >= Get5State_KnifeRound && g_PausingEnabledCvar.BoolValue;
}

public bool PauseGame(MatchTeam team, PauseType type) {

    Get5MatchPausedEvent event = new Get5MatchPausedEvent(g_MatchID, team, type);

    LogDebug("Calling Get5_OnMatchPaused()");

    Call_StartForward(g_OnMatchPaused);
    Call_PushCell(event);
    Call_Finish();

    EventLogger_LogAndDeleteEvent(event);

    return Pause(g_FixedPauseTimeCvar.IntValue, MatchTeamToCSTeam(team));
    
}

public void UnpauseGame(MatchTeam team) {

    Get5MatchUnpausedEvent event = new Get5MatchUnpausedEvent(g_MatchID, team);

    LogDebug("Calling Get5_OnMatchUnpaused()");

    Call_StartForward(g_OnMatchUnpaused);
    Call_PushCell(event);
    Call_Finish();

    EventLogger_LogAndDeleteEvent(event);

    Unpause();
    
}

public Action Command_TechPause(int client, int args) {
  if (!g_AllowTechPauseCvar.BoolValue || !Pauseable() || IsPaused()) {
    return Plugin_Handled;
  }

  g_InExtendedPause = true;

  if (client == 0) {
    PauseGame(MatchTeam_TeamNone, PauseType_Tech);
    Get5_MessageToAll("%t", "AdminForceTechPauseInfoMessage");
    return Plugin_Handled;
  }

  PauseGame(GetClientMatchTeam(client), PauseType_Tech);
  Get5_MessageToAll("%t", "MatchTechPausedByTeamMessage", client);

  return Plugin_Handled;
}

public Action Command_Pause(int client, int args) {
  if (!Pauseable() || IsPaused()) {
    return Plugin_Handled;
  }

  g_InExtendedPause = false;

  if (client == 0) {
    g_InExtendedPause = true;
    PauseGame(MatchTeam_TeamNone, PauseType_Tech);
    Get5_MessageToAll("%t", "AdminForcePauseInfoMessage");
    return Plugin_Handled;
  }

  MatchTeam team = GetClientMatchTeam(client);
  int maxPauses = g_MaxPausesCvar.IntValue;
  char pausePeriodString[32];
  if (g_ResetPausesEachHalfCvar.BoolValue) {
    Format(pausePeriodString, sizeof(pausePeriodString), " %t", "PausePeriodSuffix");
  }

  if (maxPauses > 0 && g_TeamPausesUsed[team] >= maxPauses && IsPlayerTeam(team)) {
    Get5_Message(client, "%t", "MaxPausesUsedInfoMessage", maxPauses, pausePeriodString);
    return Plugin_Handled;
  }

  int maxPauseTime = g_MaxPauseTimeCvar.IntValue;
  if (maxPauseTime > 0 && g_TeamPauseTimeUsed[team] >= maxPauseTime && IsPlayerTeam(team)) {
    Get5_Message(client, "%t", "MaxPausesTimeUsedInfoMessage", maxPauseTime, pausePeriodString);
    return Plugin_Handled;
  }

  g_TeamReadyForUnpause[MatchTeam_Team1] = false;
  g_TeamReadyForUnpause[MatchTeam_Team2] = false;

  int pausesLeft = 1;
  if (g_MaxPausesCvar.IntValue > 0 && IsPlayerTeam(team)) {
    // Update the built-in convar to ensure correct max amount is displayed
    ServerCommand("mp_team_timeout_max %d", g_MaxPausesCvar.IntValue);
    pausesLeft = g_MaxPausesCvar.IntValue - g_TeamPausesUsed[team] - 1;
  }

  // If the pause will need explicit resuming, we will create a timer to poll the pause status.
  bool need_resume = PauseGame(team, PauseType_Tactical);

  if (IsPlayer(client)) {
    Get5_MessageToAll("%t", "MatchPausedByTeamMessage", client);
  }

  if (IsPlayerTeam(team)) {
    if (need_resume) {
      g_PauseTimeUsed = g_PauseTimeUsed + g_FixedPauseTimeCvar.IntValue - 1;
      CreateTimer(1.0, Timer_PauseTimeCheck, team, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
      // Keep track of timer, since we don't want several timers created for one pause checking
      // instance.
      CreateTimer(1.0, Timer_UnpauseEventCheck, team, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }

    g_TeamPausesUsed[team]++;

    pausePeriodString = "";
    if (g_ResetPausesEachHalfCvar.BoolValue) {
      Format(pausePeriodString, sizeof(pausePeriodString), " %t", "PausePeriodSuffix");
    }

    if (g_MaxPausesCvar.IntValue > 0) {
      if (pausesLeft == 1 && g_MaxPausesCvar.IntValue > 0) {
        Get5_MessageToAll("%t", "OnePauseLeftInfoMessage", g_FormattedTeamNames[team], pausesLeft,
                          pausePeriodString);
      } else if (g_MaxPausesCvar.IntValue > 0) {
        Get5_MessageToAll("%t", "PausesLeftInfoMessage", g_FormattedTeamNames[team], pausesLeft,
                          pausePeriodString);
      }
    }
  }

  return Plugin_Handled;
}

public Action Timer_UnpauseEventCheck(Handle timer, int data) {
  if (!Pauseable()) {
    g_PauseTimeUsed = 0;
    return Plugin_Stop;
  }

  // Unlimited pause time.
  if (g_MaxPauseTimeCvar.IntValue <= 0) {
    // Reset state.
    g_PauseTimeUsed = 0;
    return Plugin_Stop;
  }

  if (!InFreezeTime()) {
    // Someone can call pause during a round and will set this timer.
    // Keep running timer until we are paused.
    return Plugin_Continue;
  } else {
    if (g_PauseTimeUsed <= 0) {
      MatchTeam team = view_as<MatchTeam>(data);
      UnpauseGame(team);
      // Reset state
      g_PauseTimeUsed = 0;
      return Plugin_Stop;
    }
    g_PauseTimeUsed--;
    LogDebug("Subtracting time used. Current time = %d", g_PauseTimeUsed);
  }

  return Plugin_Continue;
}

public Action Timer_PauseTimeCheck(Handle timer, int data) {
  if (!Pauseable() || !IsPaused() || g_FixedPauseTimeCvar.BoolValue) {
    return Plugin_Stop;
  }

  // Unlimited pause time.
  if (g_MaxPauseTimeCvar.IntValue <= 0) {
    return Plugin_Stop;
  }

  char pausePeriodString[32];
  if (g_ResetPausesEachHalfCvar.BoolValue) {
    Format(pausePeriodString, sizeof(pausePeriodString), " %t", "PausePeriodSuffix");
  }

  MatchTeam team = view_as<MatchTeam>(data);
  int timeLeft = g_MaxPauseTimeCvar.IntValue - g_TeamPauseTimeUsed[team];
  // Only count against the team's pause time if we're actually in the freezetime
  // pause and they haven't requested an unpause yet.
  if (InFreezeTime() && !g_TeamReadyForUnpause[team]) {
    g_TeamPauseTimeUsed[team]++;

    if (timeLeft == 10) {
      Get5_MessageToAll("%t", "PauseTimeExpiration10SecInfoMessage", g_FormattedTeamNames[team]);
    } else if (timeLeft % 30 == 0) {
      Get5_MessageToAll("%t", "PauseTimeExpirationInfoMessage", g_FormattedTeamNames[team],
                        timeLeft, pausePeriodString);
    }
  }
  if (timeLeft <= 0) {
    Get5_MessageToAll("%t", "PauseRunoutInfoMessage", g_FormattedTeamNames[team]);
    Unpause();
    return Plugin_Stop;
  }

  return Plugin_Continue;
}

public Action Command_Unpause(int client, int args) {
  if (!IsPaused())
    return Plugin_Handled;

  // Let console force unpause
  if (client == 0) {
    UnpauseGame(MatchTeam_TeamNone);
    Get5_MessageToAll("%t", "AdminForceUnPauseInfoMessage");
    return Plugin_Handled;
  }

  if (g_FixedPauseTimeCvar.BoolValue && !g_InExtendedPause) {
    return Plugin_Handled;
  }

  MatchTeam team = GetClientMatchTeam(client);
  g_TeamReadyForUnpause[team] = true;

  if (g_TeamReadyForUnpause[MatchTeam_Team1] && g_TeamReadyForUnpause[MatchTeam_Team2]) {
    UnpauseGame(team);
    if (IsPlayer(client)) {
      Get5_MessageToAll("%t", "MatchUnpauseInfoMessage", client);
    }
  } else if (g_TeamReadyForUnpause[MatchTeam_Team1] && !g_TeamReadyForUnpause[MatchTeam_Team2]) {
    Get5_MessageToAll("%t", "WaitingForUnpauseInfoMessage", g_FormattedTeamNames[MatchTeam_Team1],
                      g_FormattedTeamNames[MatchTeam_Team2]);
  } else if (!g_TeamReadyForUnpause[MatchTeam_Team1] && g_TeamReadyForUnpause[MatchTeam_Team2]) {
    Get5_MessageToAll("%t", "WaitingForUnpauseInfoMessage", g_FormattedTeamNames[MatchTeam_Team2],
                      g_FormattedTeamNames[MatchTeam_Team1]);
  }

  return Plugin_Handled;
}
