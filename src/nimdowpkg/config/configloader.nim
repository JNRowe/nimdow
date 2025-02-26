import
  os,
  osproc,
  parsetoml,
  strutils,
  tables,
  x11 / [x,  xlib]

import
  apprules,
  tagsettings,
  ../keys/keyutils,
  ../event/xeventmanager,
  ../logger,
  ../windowtitleposition,
  ../wmcommands

var configLoc*: string

proc findConfigPath*(): string =
  let configHome = getConfigDir()
  result = configHome & "nimdow/config.toml"
  if not fileExists(result):
    result = "/usr/share/nimdow/config.default.toml"
  if not fileExists(result):
    log "config file " & result & " does not exist", lvlError
    result = ""

type
  KeyCombo* = tuple[keycode: int, modifiers: int]
  Action* = proc(keyCombo: KeyCombo): void

  WindowSettings* = object
    gapSize*: uint
    tagCount*: uint
    borderColorUnfocused*: int
    borderColorFocused*: int
    borderColorUrgent*: int
    borderWidth*: uint
  BarSettings* = object
    height*: uint
    windowTitlePosition*: WindowTitlePosition
    fonts*: seq[string]
    # Hex values
    fgColor*, bgColor*, selectionColor*, urgentColor*: int
  MonitorSettings* = object
    tagSettings*: TagSettings
    barSettings*: BarSettings
  MonitorSettingsRef* = ref MonitorSettings

  MonitorID* = int
  Config* = ref object
    eventManager: XEventManager
    actionIdentifierTable*: Table[string, Action]
    keyComboTable*: Table[KeyCombo, Action]
    windowSettings*: WindowSettings
    xEventListener*: XEventListener
    loggingEnabled*: bool
    tagKeys*: seq[string]
    defaultMonitorSettings*: MonitorSettings
    # Specific monitor settings
    monitorSettings*: Table[MonitorID, MonitorSettings]
    appRules*: seq[AppRule]

proc newConfig*(eventManager: XEventManager): Config =
  Config(
    eventManager: eventManager,
    actionIdentifierTable: initTable[string, Action](),
    keyComboTable: initTable[KeyCombo, Action](),
    windowSettings: WindowSettings(
      gapSize: 12,
      tagCount: 9,
      borderColorUnfocused: 0x1c1b19,
      borderColorFocused: 0x519f50,
      borderColorUrgent: 0xff5555,
      borderWidth: 1
    ),
    loggingEnabled: false
  )

proc configureAction*(this: Config, actionName: string, actionInvokee: Action)
proc hookConfig*(this: Config)
proc populateBarSettings*(this: Config, barSettings: var BarSettings, settingsTable: TomlTableRef)
proc populateControlAction(this: Config, display: PDisplay, action: string, configTable: TomlTable)
proc populateKeyComboTable*(this: Config, configTable: TomlTable, display: PDisplay)
proc getKeyCombos(
  this: Config,
  configTable: TomlTable,
  display: PDisplay,
  action: string,
  keys: seq[string]
): seq[KeyCombo]
proc getKeyCombos(
  this: Config,
  configTable: TomlTable,
  display: PDisplay,
  action: string
): seq[KeyCombo]
proc getKeysForAction(this: Config, configTable: TomlTable, action: string): seq[string]
proc getModifiersForAction(this: Config, configTable: TomlTable, action: string): seq[TomlValueRef]
proc getAutostartCommands(this: Config, configTable: TomlTable): seq[string]
proc runCommands(this: Config, commands: varargs[string])

proc runAutostartCommands*(this: Config, configTable: TomlTable) =
  let autostartCommands = this.getAutostartCommands(configTable)
  this.runCommands(autostartCommands)

proc getAutostartCommands(this: Config, configTable: TomlTable): seq[string] =
  if not configTable.hasKey("autostart"):
    return
  let autoStartTable = configTable["autostart"]
  if autoStartTable.kind != TomlValueKind.Table:
    raise newException(Exception,"Invalid autostart table")

  if not autoStartTable.tableVal[].hasKey("exec"):
    raise newException(Exception, "Autostart table does not have exec key")

  for cmd in autoStartTable.tableVal[]["exec"].arrayVal:
    if cmd.kind == TomlValueKind.String:
      result.add(cmd.stringVal)
    else:
      log repr(cmd) & " is not a string", lvlWarn

proc runCommands(this: Config, commands: varargs[string]) =
  for cmd in commands:
    try:
      let process = startProcess(command = cmd, options = { poEvalCommand })
      this.eventManager.submitProcess(process)
    except:
      log "Failed to start command: " & cmd, lvlWarn

proc populateAppRules*(this: Config, configTable: TomlTable) =
  this.appRules = configTable.parseAppRules()

proc getModifierMask(modifier: TomlValueRef): int =
  if modifier.kind != TomlValueKind.String:
    log "Invalid key configuration: " & repr(modifier) & " is not a string", lvlError
    return

  if not ModifierTable.hasKey(modifier.stringVal):
    log "Invalid key configuration: " & repr(modifier) & " is not a valid key modifier", lvlError
    return

  return ModifierTable[modifier.stringVal]

proc bitorModifiers(modifiers: openarray[TomlValueRef]): int =
  for tomlElement in modifiers:
    result = result or getModifierMask(tomlElement)

proc configureAction*(this: Config, actionName: string, actionInvokee: Action) =
  this.actionIdentifierTable[actionName] = actionInvokee

proc configureExternalProcess(this: Config, command: string) =
  this.actionIdentifierTable[command] =
    proc(keyCombo: KeyCombo) =
      this.runCommands(command)

proc hookConfig*(this: Config) =
  this.xEventListener = proc(e: XEvent) =
    let mask: int = cleanMask(int(e.xkey.state))
    let keyCombo: KeyCombo = (int(e.xkey.keycode), mask)
    if this.keyComboTable.hasKey(keyCombo):
      this.keyComboTable[keyCombo](keyCombo)
  this.eventManager.addListener(this.xEventListener, KeyPress)

proc populateDefaultMonitorSettings(this: Config, display: PDisplay) =
  this.defaultMonitorSettings = MonitorSettings()

  this.defaultMonitorSettings.barSettings = BarSettings(
      height: 20,
      windowTitlePosition: wtpCenter,
      fonts: @[
        "monospace:size=10:antialias=true",
        "NotoColorEmoji:size=10:antialias=true"
      ],
      fgColor: 0xfce8c3,
      bgColor: 0x1c1b19,
      selectionColor: 0x519f50,
      urgentColor: 0xef2f27
  )

  this.defaultMonitorSettings.tagSettings = createDefaultTagSettings()

proc populateMonitorSettings(this: Config, configTable: TomlTable, display: PDisplay) =
  this.populateDefaultMonitorSettings(display)

  if not configTable.hasKey("monitors"):
    return

  let monitorsTable = configTable["monitors"]
  if monitorsTable.kind != TomlValueKind.Table:
    raise newException(Exception, "Invalid monitors config table")

  # Change default monitor settings.
  if monitorsTable.hasKey("default"):
    let settingsTable = configTable["settings"].tableVal
    this.populateBarSettings(this.defaultMonitorSettings.barSettings, settingsTable)

    let changedDefaults = monitorsTable["default"]
    if changedDefaults.hasKey("tags"):
      let tagsTable = changedDefaults["tags"]
      if tagsTable.kind == TomlValueKind.Table:
        # this.defaultMonitorSettings.populateTagSettings(tagsTable.tableVal, display)
        this.defaultMonitorSettings.tagSettings.populateTagSettings(tagsTable.tableVal)

  # Populate settings per-monitor
  for monitorIDStr, settingsToml in monitorsTable.tableVal.pairs():
    if monitorIDStr == "default":
      continue

    if settingsToml.kind != TomlValueKind.Table:
      log "Settings table incorrect type for monitor ID: " & monitorIDStr
      continue

    # Parse the ID into a integer.
    var monitorID: MonitorID
    try:
      monitorID = parseInt(monitorIDStr)
    except:
      log "Invalid monitor ID: " & monitorIDStr, lvlError
      continue

    var monitorSettings: MonitorSettings = deepcopy this.defaultMonitorSettings

    if settingsToml.hasKey("tags"):
      let tagsTable = settingsToml["tags"]
      if tagsTable.kind == TomlValueKind.Table:
        monitorSettings.tagSettings.populateTagSettings(tagsTable.tableVal)

    this.monitorSettings[monitorID] = monitorSettings

proc populateControlsTable(this: Config, configTable: TomlTable, display: PDisplay) =
  if not configTable.hasKey("controls"):
    return
  # Populate window manager controls
  let controlsTable = configTable["controls"]
  if controlsTable.kind != TomlValueKind.Table:
    raise newException(Exception, "Invalid controls config table")

  for action in controlsTable.tableVal.keys():
    let command = parseEnum[WMCommand](action)
    this.populateControlAction(display, ($command).toLower(), controlsTable[action].tableVal[])

proc populateExternalProcessSettings(this: Config, configTable: TomlTable, display: PDisplay) =
  if not configTable.hasKey("startProcess"):
    return

  # Populate external commands
  let externalProcessesTable = configTable["startProcess"]

  if externalProcessesTable.kind != TomlValueKind.Array:
    raise newException(Exception, "No \"startProcess\" commands defined!")

  for commandDeclaration in externalProcessesTable.arrayVal:
    if commandDeclaration.kind != TomlValueKind.Table:
      raise newException(Exception, "Invalid \"startProcess\" configuration command!")
    if not commandDeclaration.tableVal[].hasKey("command"):
      raise newException(Exception, "Invalid \"startProcess\" configuration: Missing \"command\" string!")

    let command = commandDeclaration.tableVal["command"].stringVal
    this.configureExternalProcess(command)
    this.populateControlAction(
      display,
      command,
      commandDeclaration.tableVal[]
    )

proc loadHexValue(this: Config, settingsTable: TomlTableRef, valueName: string): int =
  if settingsTable.hasKey(valueName):
    let setting = settingsTable[valueName]
    if setting.kind == TomlValueKind.String:
      return fromHex[int](setting.stringVal)
    else:
      raise newException(Exception, valueName & " is not a proper hex value! Ensure it is wrapped in double quotes")
  return -1

proc populateBarSettings*(this: Config, barSettings: var BarSettings, settingsTable: TomlTableRef) =
  if settingsTable.hasKey("windowTitlePosition"):
    let wtpToml = settingsTable["windowTitlePosition"]
    if wtpToml.kind != TomlValueKind.String:
      raise newException(Exception, "windowTitlePosition needs to be a string!")

    let windowTitlePosition = wtpToml.stringVal.toLower()
    if windowTitlePosition == "center" or windowTitlePosition == "centre":
      barSettings.windowTitlePosition = wtpCenter
    elif windowTitlePosition == "left":
      barSettings.windowTitlePosition = wtpLeft
    else:
      raise newException(Exception, "windowTitlePosition needs to be: center, centre, or left!")

  let bgColor = this.loadHexValue(settingsTable, "barBackgroundColor")
  if bgColor != -1:
    barSettings.bgColor = bgColor

  let fgColor = this.loadHexValue(settingsTable, "barForegroundColor")
  if fgColor != -1:
    barSettings.fgColor = fgColor

  let selectionColor = this.loadHexValue(settingsTable, "barSelectionColor")
  if selectionColor != -1:
    barSettings.selectionColor = selectionColor

  let urgentColor = this.loadHexValue(settingsTable, "barUrgentColor")
  if urgentColor != -1:
    barSettings.urgentColor = urgentColor

  if settingsTable.hasKey("barHeight"):
    let barHeight = settingsTable["barHeight"]
    if barHeight.kind == TomlValueKind.Int:
      barSettings.height = max(0, barHeight.intVal).uint

  if settingsTable.hasKey("barFonts"):
    let barFonts = settingsTable["barFonts"]
    if barFonts.kind != TomlValueKind.Array:
      raise newException(Exception, "barFonts is not an array of strings!")

    var fonts: seq[string]
    for font in barFonts.arrayVal:
      if font.kind == TomlValueKind.String:
        fonts.add(font.stringVal)
      else:
        raise newException(Exception, "Invalid font - must be a string!")
    barSettings.fonts = fonts

proc populateGeneralSettings*(this: Config, configTable: TomlTable) =
  if not configTable.hasKey("settings") or configTable["settings"].kind != TomlValueKind.Table:
    raise newException(Exception, "Invalid settings table")

  let settingsTable = configTable["settings"].tableVal
  this.populateBarSettings(this.defaultMonitorSettings.barSettings, settingsTable)

  # Window settings
  if settingsTable.hasKey("gapSize"):
    let gapSizeSetting = settingsTable["gapSize"]
    if gapSizeSetting.kind == TomlValueKind.Int:
      this.windowSettings.gapSize = max(0, gapSizeSetting.intVal).uint
    else:
      log "gapSize is not an integer value!", lvlWarn

  if settingsTable.hasKey("borderWidth"):
    let borderWidthSetting = settingsTable["borderWidth"]
    if borderWidthSetting.kind == TomlValueKind.Int:
      this.windowSettings.borderWidth = max(0, borderWidthSetting.intVal).uint
    else:
      log "borderWidth is not an integer value!", lvlWarn

  let unfocusedBorderVal = this.loadHexValue(settingsTable, "borderColorUnfocused")
  if unfocusedBorderVal != -1:
    this.windowSettings.borderColorUnfocused = unfocusedBorderVal

  let focusedBorderVal = this.loadHexValue(settingsTable, "borderColorFocused")
  if focusedBorderVal != -1:
    this.windowSettings.borderColorFocused = focusedBorderVal

  let urgentBorderVal = this.loadHexValue(settingsTable, "borderColorUrgent")
  if urgentBorderVal != -1:
    this.windowSettings.borderColorUrgent = urgentBorderVal

  # Bar settings
  for monitorSettings in this.monitorSettings.mvalues():
    this.populateBarSettings(monitorSettings.barSettings, settingsTable)

  # General settings
  if settingsTable.hasKey("loggingEnabled"):
    let loggingEnabledSetting = settingsTable["loggingEnabled"]
    if loggingEnabledSetting.kind == TomlValueKind.Bool:
      this.loggingEnabled = loggingEnabledSetting.boolVal
    else:
      raise newException(Exception, "loggingEnabled is not true/false!")

proc populateKeyComboTable*(this: Config, configTable: TomlTable, display: PDisplay) =
  ## Reads the user's configuration file and set the keybindings.
  this.populateControlsTable(configTable, display)
  this.populateMonitorSettings(configTable, display)
  this.populateExternalProcessSettings(configTable, display)

proc loadConfigFile*(): TomlTable =
  ## Reads the user's configuration file into a table.
  ## Set configLoc before calling this procedure,
  ## if you would like to use an alternate config file.
  if configLoc.len == 0:
    configLoc = findConfigPath()
  let loadedConfig = parsetoml.parseFile(configLoc)
  if loadedConfig.kind != TomlValueKind.Table:
    raise newException(Exception, "Invalid config file!")
  return loadedConfig.tableVal[]

proc populateControlAction(this: Config, display: PDisplay, action: string, configTable: TomlTable) =
  let keyCombos = this.getKeyCombos(configTable, display, action)
  for keyCombo in keyCombos:
    if this.actionIdentifierTable.hasKey(action):
      this.keyComboTable[keyCombo] = this.actionIdentifierTable[action]
    else:
      raise newException(Exception, "Invalid key config action: \"" & action & "\" does not exist")

proc getKeyCombos(
  this: Config,
  configTable: TomlTable,
  display: PDisplay,
  action: string,
  keys: seq[string]
): seq[KeyCombo] =
  ## Gets the KeyCombos associated with the given `action` from the table.
  let modifierArray = this.getModifiersForAction(configTable, action)
  let modifiers: int = bitorModifiers(modifierArray)
  for key in keys:
    let keycode = key.toKeycode(display)
    result.add((keycode, cleanMask(modifiers)))

proc getKeyCombos(
  this: Config,
  configTable: TomlTable,
  display: PDisplay,
  action: string
): seq[KeyCombo] =
  return this.getKeyCombos(
    configTable,
    display,
    action,
    this.getKeysForAction(configTable, action)
  )

proc getKeysForAction(this: Config, configTable: TomlTable, action: string): seq[string] =
  if not configTable.hasKey("keys"):
    log "\"keys\" not found in config table for action \"" & action & "\"", lvlError
    return
  var tomlKeys = configTable["keys"]
  if tomlKeys.kind != TomlValueKind.Array:
    log "Invalid key config for action: " & action & "\n\"keys\" must be an array of strings", lvlError
    return

  for tomlKey in tomlKeys.arrayVal:
    if tomlKey.kind != TomlValueKind.String:
      log "Invalid key configuration: " & repr(tomlKey) & " is not a string", lvlError
      return
    result.add(tomlKey.stringVal)

proc getModifiersForAction(this: Config, configTable: TomlTable, action: string): seq[TomlValueRef] =
  if configTable.hasKey("modifiers"):
    var modifiersConfig = configTable["modifiers"]
    if modifiersConfig.kind != TomlValueKind.Array:
      log "Invalid key configuration: " & repr(modifiersConfig) & " is not an array", lvlError
    return modifiersConfig.arrayVal

