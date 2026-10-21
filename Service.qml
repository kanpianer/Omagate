import QtQuick
import Quickshell
import Quickshell.Io
import "CountryLookup.js" as CountryLookup
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false
  property bool installed: false
  property bool serviceAvailable: false
  property bool refreshing: false
  property bool busy: actionProcess.running || renameProcess.running || directOnlineProcess.running
  property var accounts: []
  readonly property var savedAccounts: {
    var list = []
    for (var i = 0; i < accounts.length; i++) {
      if (accounts[i].name !== "VPNGate_Direct") list.push(accounts[i])
    }
    return list
  }
  property string selectedAccountName: ""
  property string tunnelAddress: ""
  property bool hasVpnDefaultRoute: false
  property string actionStatus: ""
  property string lastError: ""
  property string actionKind: ""
  property string actionAccountName: ""
  property string connectAfterDisconnect: ""
  property string connectTargetName: ""
  property int desiredState: -1
  property bool importing: pickerProcess.running || importProcess.running
  readonly property string pickerPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.kanpianer.omagate/vpn-file-picker"
  readonly property string setupPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.kanpianer.omagate/softether-setup"
  property var setupState: ({})
  property bool setupChecked: false
  property bool checkingSetup: false
  property bool preparingSetup: false
  property bool installingClient: false
  property string setupError: ""
  readonly property bool setupReady: setupState.ready === true
  readonly property bool setupRequired: setupChecked && !setupReady
  property double installStartedAt: 0

  property var onlineNodes: []
  property bool fetchingOnline: fetchOnlineProcess.running
  property bool addingOnline: addOnlineProcess.running
  property string onlineError: ""
  property var pendingConnectNode: null
  property var directConnectedNode: null
  property var pendingDirectConnectNode: null
  readonly property bool configuringDirect: directOnlineProcess.running
  readonly property string vpngateHelperPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.kanpianer.omagate/vpngate-helper"

  property string renamingOldName: ""
  property string renamingNewName: ""
  property string _renameOutput: ""
  property string _renameError: ""
  readonly property bool renaming: renameProcess.running

  signal selectionRequested(string accountName)
  signal accountRenamed(string oldName, string newName)
  signal importCompleted(bool success, string message)
  signal onlineNodesFetched(bool success, string errorMsg)
  signal onlineNodeAdded(bool success, string accountName, string message)
  signal connectionRecorded(string accountName)

  readonly property string configuredAccountName: boundedSetting("accountName", "", 128)
  readonly property string lastConnectedAccountName: {
    var value = String(setting("lastConnectedAccount", ""))
    return value.length <= 128 ? value : ""
  }
  readonly property string adapterName: boundedSetting("adapterName", "vpn_vpn", 15)
  readonly property string networkProfileName: boundedSetting("networkProfileName", "SoftEther VPN Network", 128)
  readonly property string settingsError: Model.settingsError(
    configuredAccountName, networkProfileName, adapterName)
  readonly property bool settingsValid: settingsError === ""
  readonly property string controlPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.kanpianer.omagate/softether-control"
  readonly property int refreshIntervalSec: boundedInt(setting("refreshIntervalSec", 10), 10, 5, 300)
  // Poll at the configured rate while the panel is open or a tunnel is
  // active; when nobody is looking and nothing is connected, back off so an
  // idle widget is not spawning vpncmd every few seconds.
  readonly property int pollingIntervalMs: {
    var base = refreshIntervalSec * 1000
    if (panelOpen || activeAccount !== null || desiredState === 1 || busy || !serviceAvailable) return base
    return Math.max(base, 30000)
  }
  readonly property var selectedAccount: accountNamed(selectedAccountName)
  readonly property var connectedAccount: firstAccountWithState("connected")
  readonly property var connectingAccount: firstAccountWithState("connecting")
  readonly property var activeAccount: connectedAccount || connectingAccount
  // The switch follows the tunnel, not the client session: a session SoftEther
  // still lists after the link dropped has no address and no default route, and
  // must not keep the switch on as if the VPN were connected.
  readonly property bool active: Model.switchOn({
    desiredState: desiredState,
    connected: connectedAccount !== null,
    connecting: connectingAccount !== null,
    usable: usable
  })
  readonly property bool usable: connectedAccount !== null && tunnelAddress !== "" && hasVpnDefaultRoute
  readonly property bool connectAnimationActive: Model.shouldPulse(actionKind)
  function displayNameForAccount(acc) {
    if (!acc) return ""
    if (acc.name === "VPNGate_Direct") {
      if (directConnectedNode && directConnectedNode.name) return directConnectedNode.name
      return directConnectedNode ? directConnectedNode.country : "VPN Gate"
    }
    return acc.name || acc.country
  }

  // The relay list is remote input. The helper authenticates and validates it,
  // and these checks keep any corrupt or tampered entry from reaching vpncmd
  // through the UI as well.
  function isEndpointIp(value) {
    var text = String(value || "").trim()
    if (text.length < 2 || text.length > 45) return false
    var v4 = text.match(/^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/)
    if (v4) {
      for (var i = 1; i <= 4; i++) {
        if (Number(v4[i]) > 255) return false
      }
      return true
    }
    if (text.indexOf(":") < 0 || text.indexOf(".") >= 0 || text.indexOf("%") >= 0) return false
    if (!/^[0-9A-Fa-f:]+$/.test(text)) return false
    var compressed = text.indexOf("::")
    if (compressed !== text.lastIndexOf("::")) return false
    var groups = text.split(":")
    var count = 0
    for (var j = 0; j < groups.length; j++) {
      if (groups[j] === "") continue
      if (groups[j].length > 4) return false
      count++
    }
    return compressed >= 0 ? count <= 7 : count === 8
  }

  function isEndpointPort(value) {
    var text = String(value || "").trim()
    if (!/^[0-9]{1,5}$/.test(text)) return false
    var port = Number(text)
    return port >= 1 && port <= 65535
  }

  function isEndpointNode(node) {
    return !!node && isEndpointIp(node.ip) && isEndpointPort(node.port)
  }

  readonly property string country: {
    if (activeAccount && activeAccount.name === "VPNGate_Direct") {
      return directConnectedNode ? (directConnectedNode.country || "VPN") : "VPN"
    }
    return selectedAccount ? selectedAccount.country : "VPN"
  }
  // What the panel header should show: a connection the user just asked for
  // (including a direct VPN Gate node) wins over the old session, so the top
  // row switches as soon as the action starts instead of after the teardown.
  readonly property var headerTarget: {
    if (desiredState === 1) {
      if (directConnectedNode) return directConnectedNode
      if (selectedAccount) return selectedAccount
    }
    return activeAccount || selectedAccount
  }
  readonly property string headerFlag: {
    var target = headerTarget
    return target ? String(target.flag || "🏳") : ""
  }
  readonly property string headerName: {
    var target = headerTarget
    if (!target) return ""
    if (target.name === "VPNGate_Direct") return displayNameForAccount(target)
    return String(target.name || target.country || "")
  }
  readonly property string nodeName: headerName !== "" ? headerName : country
  readonly property string state: Model.presentationState({
    installed: installed,
    serviceAvailable: serviceAvailable,
    lastError: settingsError || lastError,
    actionKind: actionKind,
    desiredState: desiredState,
    connecting: connectingAccount !== null,
    connected: connectedAccount !== null,
    usable: usable
  })
  readonly property string statusText: {
    if (!settingsValid) return settingsError
    if (!installed) return "SoftEther is not installed"
    if (!serviceAvailable) return "SoftEther client service is stopped"
    if (savedAccounts.length === 0 && !activeAccount) return "No imported VPN profiles"
    if (lastError !== "") {
      if (lastError.indexOf("timed out") !== -1) return "Connection timed out · " + nodeName
      return "Connection failed · " + nodeName
    }
    if (busy && actionKind === "connect") {
      var targetName = actionAccountName === "VPNGate_Direct" && directConnectedNode
        ? directConnectedNode.name : (actionAccountName || nodeName)
      return "Connecting to " + targetName + "…"
    }
    if (busy && actionKind === "disconnect") return "Disconnecting…"
    if (busy && actionKind === "delete") return "Deleting " + (actionAccountName || nodeName) + "…"
    if (renaming) return "Renaming " + (renamingOldName || "node") + "…"
    if (importing) return "Importing VPN profiles…"
    if (connectingAccount) return "Connecting to " + displayNameForAccount(connectingAccount) + "…"
    if (connectedAccount && !usable) return "Connected; waiting for VPN route"
    if (connectedAccount) return "Connected to " + displayNameForAccount(connectedAccount)
    if (selectedAccount) return "Disconnected · " + nodeName + " selected"
    return "Disconnected · no node selected"
  }
  readonly property string tooltipText: "Omagate · " + statusText

  property string _accountsOutput: ""
  property string _accountsError: ""
  property string _accountsSignature: ""
  property var _countryCache: ({})
  property string _addressOutput: ""
  property string _routeOutput: ""
  property string _actionOutput: ""
  property string _actionError: ""
  property string _pickerOutput: ""
  property string _importOutput: ""
  property string _importError: ""
  property string _onlineOutput: ""
  property string _onlineError: ""
  property string _addOnlineOutput: ""
  property string _addOnlineError: ""
  property string _directOnlineOutput: ""
  property string _directOnlineError: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function boundedSetting(name, fallback, maximum) {
    var value = String(setting(name, fallback))
    // Return a deliberately invalid sentinel without retaining an oversized
    // duplicate in the service model.
    return value.length <= maximum ? value : "\n"
  }

  function boundedInt(value, fallback, min, max) {
    var parsed = parseInt(String(value), 10)
    if (!isFinite(parsed)) parsed = fallback
    return Math.max(min, Math.min(max, parsed))
  }

  function accountNamed(name) {
    var target = String(name || "")
    for (var i = 0; i < accounts.length; i++)
      if (String(accounts[i].name || "") === target) return accounts[i]
    return null
  }

  function firstAccountWithState(kind) {
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].statusKind === kind) return accounts[i]
    return null
  }

  // CountryLookup runs regular expressions over the node name. The same names
  // come back on every poll, so remember the result instead of recomputing it.
  function countryDetailsFor(name) {
    var key = String(name || "")
    var cached = _countryCache[key]
    if (cached !== undefined) return cached
    var details = CountryLookup.countryDetails(key)
    _countryCache[key] = details
    return details
  }

  property string _recordedConnectionName: ""
  function recordConnection(name) {
    var accountName = String(name || "")
    if (accountName === "" || accountName === "VPNGate_Direct") return
    if (accountName === _recordedConnectionName) return
    _recordedConnectionName = accountName
    connectionRecorded(accountName)
  }

  // SoftEther returns the same account table every few seconds. Reassigning
  // `accounts` for an unchanged table makes every binding, the saved-node
  // repeater, and the sorted display list rebuild for nothing.
  function accountSignature(list) {
    var parts = []
    for (var i = 0; i < list.length; i++) {
      var account = list[i]
      parts.push(account.name, account.statusKind, account.server,
        account.hub, account.adapter, account.flag, account.country, account.countryCode)
    }
    return parts.join("\u0001")
  }

  function choosePreferredAccount() {
    // Never fight a connection the user just started; its target is already
    // selected and a refresh landing mid-switch must not revert it.
    if (desiredState === 1 || (busy && actionKind === "connect")) return

    if (activeAccount && activeAccount.name !== "VPNGate_Direct") {
      selectedAccountName = activeAccount.name
      return
    }

    // Keep an explicit choice that still exists instead of silently jumping
    // to another node on every refresh.
    if (selectedAccountName !== "" && accountNamed(selectedAccountName)) return

    // The most recently connected node is what the header should remember.
    var last = lastConnectedAccountName
    if (last !== "" && last !== "VPNGate_Direct" && accountNamed(last)) {
      selectedAccountName = last
      return
    }

    var configured = configuredAccountName
    if (configured !== "" && configured !== "VPNGate_Direct" && accountNamed(configured)) {
      selectedAccountName = configured
      return
    }

    // Deliberately no fallback to the first saved node: a list the user has
    // not touched should stay unselected until a node is picked or connected.
    selectedAccountName = ""
  }

  function elide(text) {
    return Model.elideError(text)
  }

  function checkSetup() {
    if (!settingsValid || setupCheckProcess.running) return
    checkingSetup = true
    setupCheckProcess.command = ["timeout", "--signal=TERM", "--kill-after=2s", "10s",
      setupPath, "check", adapterName, networkProfileName]
    setupCheckProcess.running = true
  }

  function prepareSetup() {
    if (preparingSetup || installingClient) return
    if (setupState.client !== true) {
      installClient()
      return
    }
    preparingSetup = true
    setupError = ""
    prepareProcess.command = ["timeout", "--signal=TERM", "--kill-after=5s", "120s",
      setupPath, "prepare", adapterName, networkProfileName]
    prepareProcess.running = true
  }

  function installClient() {
    if (installingClient) return
    installingClient = true
    installStartedAt = Date.now()
    setupError = ""
    showNotification("Omagate", "Installing the SoftEther client in a terminal. Enter your password there if asked.", false)
    Quickshell.execDetached([setupPath, "install"])
    installPollTimer.restart()
  }

  function refresh() {
    if (!settingsValid) {
      refreshing = false
      serviceAvailable = false
      accounts = []
      tunnelAddress = ""
      hasVpnDefaultRoute = false
      return
    }
    if (!setupChecked || !setupReady) checkSetup()
    if (!installed) {
      if (!whichProcess.running) {
        whichProcess.command = ["which", "vpncmd"]
        whichProcess.running = true
      }
      return
    }
    refreshAccounts()
    if (connectedAccount !== null || connectingAccount !== null || desiredState === 1 || (busy && actionKind === "connect")) {
      refreshNetwork()
    } else {
      tunnelAddress = ""
      hasVpnDefaultRoute = false
    }
  }

  function refreshAccounts() {
    if (accountsProcess.running) return
    refreshing = true
    _accountsOutput = ""
    _accountsError = ""
    accountsProcess.command = ["timeout", "--signal=TERM", "--kill-after=3s", "10s",
      controlPath, "accounts"]
    accountsProcess.running = true
  }

  function refreshNetwork() {
    if (!addressProcess.running) {
      _addressOutput = ""
      addressProcess.command = ["timeout", "--signal=TERM", "--kill-after=3s", "9s",
        controlPath, "address", adapterName]
      addressProcess.running = true
    }
    if (!routeProcess.running) {
      _routeOutput = ""
      routeProcess.command = ["timeout", "--signal=TERM", "--kill-after=3s", "9s",
        controlPath, "routes"]
      routeProcess.running = true
    }
  }

  function disconnectVpn() {
    stopConnectionTimeout()
    connectionTimedOut = false
    connectTargetName = ""
    if (!settingsValid) {
      lastError = settingsError
      return
    }
    if (!serviceAvailable) return

    if (actionProcess.running) {
      if (actionKind === "connect") {
        desiredState = 0
        actionStatus = "Disconnecting…"
        connectAfterDisconnect = ""
        actionProcess.running = false
        delayedRefresh.restart()
        return
      }
      if (actionKind === "disconnect") {
        return
      }
    }

    var current = activeAccount || selectedAccount || (accounts.length > 0 ? accounts[0] : null)
    if (current && current.name) {
      desiredState = 0
      runAction("disconnect", current.name, "")
    }
  }

  function connectVpn() {
    if (!settingsValid) {
      lastError = settingsError
      return
    }
    if (busy || !serviceAvailable) return
    var target = selectedAccount
    if (!target) {
      lastError = "Select a VPN node first"
      return
    }
    if (target.name !== "VPNGate_Direct") {
      directConnectedNode = null
      pendingDirectConnectNode = null
    }
    connectTargetName = target.name
    desiredState = 1
    startConnectionTimeout()
    var current = activeAccount
    // This only runs while the switch is off, and it is off because nothing
    // is routed: any session the client still lists is stale, so tear it down
    // instead of asking a client that believes it is online to connect again.
    if (current) {
      runAction("disconnect", current.name, target.name)
    } else {
      runAction("connect", target.name, "")
    }
  }

  function connectToAccount(name) {
    if (!Model.validAccountName(name, false)) {
      lastError = "Invalid SoftEther account name"
      return
    }
    var account = accountNamed(name)
    if (!account || busy || !serviceAvailable) return
    if (name !== "VPNGate_Direct") {
      directConnectedNode = null
      pendingDirectConnectNode = null
    }
    selectedAccountName = account.name
    selectionRequested(account.name)
    connectTargetName = account.name
    desiredState = 1
    startConnectionTimeout()
    var current = activeAccount
    // Picking the node the client still lists while the tunnel is down has to
    // reconnect, not fall through to a connect the client would reject.
    if (current && (current.name !== account.name || !usable)) {
      runAction("disconnect", current.name, account.name)
    } else {
      runAction("connect", account.name, "")
    }
  }

  function toggle() {
    if (active || activeAccount !== null || (busy && actionKind === "connect") || desiredState === 1) disconnectVpn()
    else connectVpn()
  }

  function selectAccount(name) {
    if (!Model.validAccountName(name, false)) {
      lastError = "Invalid SoftEther account name"
      return
    }
    var account = accountNamed(name)
    if (!account || busy) return
    var current = activeAccount
    selectedAccountName = account.name
    selectionRequested(account.name)
    connectTargetName = account.name

    if (current && current.name !== account.name) {
      desiredState = 1
      runAction("disconnect", current.name, account.name)
    }
  }

  function deleteAccount(name) {
    if (!Model.validAccountName(name, false)) {
      lastError = "Invalid SoftEther account name"
      return
    }
    if (actionProcess.running || whichProcess.running) return
    if (selectedAccountName === name) {
      selectedAccountName = ""
    }
    runAction("delete", name, "")
  }

  function renameAccount(oldName, newName) {
    if (!oldName || !newName || renameProcess.running || actionProcess.running) return
    if (!Model.validAccountName(newName, false)) {
      lastError = "Invalid SoftEther account name"
      return
    }
    _renameOutput = ""
    _renameError = ""
    renamingOldName = oldName
    renamingNewName = newName
    renameProcess.command = ["timeout", "--signal=TERM", "--kill-after=5s", "15s",
      controlPath, "rename", oldName, newName]
    renameProcess.running = true
  }

  function runAction(kind, accountName, nextAccountName) {
    if (actionProcess.running || !accountName || !settingsValid
        || !Model.validAccountName(accountName, false)) {
      if (!settingsValid) lastError = settingsError
      else if (accountName && !Model.validAccountName(accountName, false))
        lastError = "Invalid SoftEther account name"
      return
    }
    if (kind === "connect") {
      startConnectionTimeout()
    } else {
      stopConnectionTimeout()
    }
    actionKind = kind
    actionAccountName = accountName
    connectAfterDisconnect = String(nextAccountName || "")
    actionStatus = kind === "connect" ? "Connecting…"
      : (kind === "delete" ? "Deleting…" : "Disconnecting…")
    lastError = ""
    _actionOutput = ""
    _actionError = ""
    var actionTimeout = kind === "connect" ? "11s" : "100s"
    var killTimeout = kind === "connect" ? "3s" : "70s"
    actionProcess.command = ["timeout", "--signal=TERM", "--kill-after=" + killTimeout, actionTimeout,
      controlPath, kind, accountName, networkProfileName, adapterName]
    actionProcess.running = true
  }

  function openImportDialog() {
    if (!serviceAvailable || busy || importing) return
    _pickerOutput = ""
    pickerProcess.command = [pickerPath]
    pickerProcess.running = true
  }

  function importFiles(fileList) {
    if (!fileList || fileList.length === 0 || importProcess.running) return
    _importOutput = ""
    _importError = ""
    var cmd = ["timeout", "--signal=TERM", "--kill-after=5s", "60s", controlPath, "import"]
    for (var i = 0; i < fileList.length; i++) {
      cmd.push(fileList[i])
    }
    importProcess.command = cmd
    importProcess.running = true
  }

  function fetchOnlineNodes(force) {
    if (fetchOnlineProcess.running) return
    _onlineOutput = ""
    _onlineError = ""
    onlineError = ""
    var args = ["timeout", "--signal=TERM", "--kill-after=5s", "75s", vpngateHelperPath, "fetch"]
    if (force === true) args.push("--force")
    fetchOnlineProcess.command = args
    fetchOnlineProcess.running = true
  }

  function addOnlineNode(node) {
    if (!node || !node.ip || !node.port || !node.name) return
    if (!isEndpointNode(node)) {
      lastError = "Refusing invalid VPN Gate endpoint"
      showNotification("Omagate", lastError, true)
      return
    }
    if (addOnlineProcess.running) return
    _addOnlineOutput = ""
    _addOnlineError = ""
    addOnlineProcess.command = ["timeout", "--signal=TERM", "--kill-after=3s", "10s",
      vpngateHelperPath, "add", String(node.ip), String(node.port), String(node.name), adapterName]
    addOnlineProcess.running = true
  }

  function connectToOnlineNode(node) {
    if (!node || !node.name) return
    if (!isEndpointNode(node)) {
      lastError = "Refusing invalid VPN Gate endpoint"
      showNotification("Omagate", lastError, true)
      return
    }
    var targetIp = String(node.ip || "").trim()
    var targetName = String(node.name || "").trim()
    var existing = null
    for (var i = 0; i < accounts.length; i++) {
      var acc = accounts[i]
      if (acc.name === "VPNGate_Direct") continue
      var accHost = (acc.server || "").split(":")[0].trim()
      if (acc.name === targetName || (targetIp !== "" && accHost === targetIp)) {
        existing = acc
        break
      }
    }
    if (existing) {
      directConnectedNode = null
      connectToAccount(existing.name)
    } else {
      connectOnlineDirect(node)
    }
  }

  function connectOnlineDirect(node) {
    if (!settingsValid) {
      lastError = settingsError
      return
    }
    if (busy || !serviceAvailable || !node || !node.ip || !node.port) return
    if (!isEndpointNode(node)) {
      lastError = "Refusing invalid VPN Gate endpoint"
      showNotification("Omagate", lastError, true)
      return
    }

    var current = activeAccount
    if (current && current.name === "VPNGate_Direct") {
      var curHost = (current.server || "").split(":")[0].trim()
      if (curHost === String(node.ip).trim() && usable) {
        return
      }
    }

    directConnectedNode = node
    connectTargetName = "VPNGate_Direct"
    desiredState = 1
    startConnectionTimeout()

    if (current) {
      pendingDirectConnectNode = node
      runAction("disconnect", current.name, "")
      return
    }

    startDirectOnlineProcess(node)
  }

  function startDirectOnlineProcess(node) {
    if (!isEndpointNode(node)) {
      lastError = "Refusing invalid VPN Gate endpoint"
      connectTargetName = ""
      desiredState = -1
      stopConnectionTimeout()
      return
    }
    startConnectionTimeout()
    directConnectedNode = node
    connectTargetName = "VPNGate_Direct"
    actionKind = "connect"
    actionAccountName = "VPNGate_Direct"
    actionStatus = "Connecting to " + (node.name || node.country || "node") + "…"
    lastError = ""
    _directOnlineOutput = ""
    _directOnlineError = ""
    directOnlineProcess.command = ["timeout", "--signal=TERM", "--kill-after=3s", "10s",
      vpngateHelperPath, "direct", String(node.ip), String(node.port), adapterName]
    directOnlineProcess.running = true
  }

  property bool _ready: false
  property bool _wasUsable: false

  Component.onCompleted: {
    refresh()
    checkSetup()
    Qt.callLater(function() {
      _wasUsable = usable
      _ready = true
    })
  }
  onSettingsChanged: {
    choosePreferredAccount()
    if (!settingsValid) lastError = settingsError
    else if (lastError.indexOf("Invalid ") === 0) lastError = ""
    setupChecked = false
    checkSetup()
  }
  onUsableChanged: {
    if (usable) {
      stopConnectionTimeout()
      if (connectedAccount) recordConnection(connectedAccount.name)
      if (_ready && !_wasUsable) {
        var targetName = (connectedAccount ? displayNameForAccount(connectedAccount) : "") || nodeName || "VPN"
        showNotification("Omagate", "Connected to " + targetName, false)
      }
    }
    _wasUsable = usable
  }

  property bool connectionTimedOut: false

  Timer {
    id: connectionTimeoutTimer
    interval: 9000
    repeat: false
    onTriggered: root.handleConnectionTimeout()
  }

  function startConnectionTimeout() {
    connectionTimedOut = false
    connectionTimeoutTimer.restart()
  }

  function stopConnectionTimeout() {
    connectionTimeoutTimer.stop()
  }

  function handleConnectionTimeout() {
    connectionTimeoutTimer.stop()
    if (root.usable && root.connectedAccount !== null) return

    connectionTimedOut = true
    lastError = "Connection timed out after 9 seconds"
    desiredState = -1
    actionKind = ""
    actionAccountName = ""
    actionStatus = ""

    if (directOnlineProcess.running) {
      directOnlineProcess.running = false
    }

    if (actionProcess.running) {
      actionProcess.running = false
    }

    disconnectVpn()

    showNotification("Omagate", lastError, true)

    delayedRefresh.restart()
  }

  Timer {
    interval: root.pollingIntervalMs
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 300
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: settleDesiredState
    interval: 12000
    repeat: false
    onTriggered: {
      root.desiredState = -1
      root.connectTargetName = ""
    }
  }

  Timer {
    id: installPollTimer
    interval: 3000
    repeat: true
    onTriggered: {
      if (!root.installingClient) {
        stop()
        return
      }
      if (Date.now() - root.installStartedAt > 15 * 60 * 1000) {
        stop()
        root.installingClient = false
        root.setupError = "Timed out waiting for the client install. Check the terminal window."
        return
      }
      root.checkSetup()
    }
  }

  Process {
    id: setupCheckProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: setupCheckStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: setupCheckStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.checkingSetup = false
      var stdout = Model.bounded(setupCheckStdout.text || "", 65536)
      var stderr = Model.bounded(setupCheckStderr.text || "", 4096)
      var parsed = null
      if (exitCode === 0 && stdout !== null) {
        try { parsed = JSON.parse(stdout) } catch (error) { parsed = null }
      }
      if (!parsed || typeof parsed !== "object") {
        root.setupChecked = true
        root.setupState = ({
          ready: false,
          client: root.installed,
          serviceActive: root.serviceAvailable,
          serviceEnabled: false,
          adapterPresent: false,
          profilePresent: false,
          profileMatches: false
        })
        root.setupError = root.elide(stderr || stdout || "Could not check setup")
        return
      }
      root.setupState = parsed
      root.setupChecked = true
      root.setupError = ""
      if (parsed.client === true && !root.installed && !whichProcess.running) {
        whichProcess.command = ["which", "vpncmd"]
        whichProcess.running = true
      }
      if (root.installingClient && parsed.client === true) {
        installPollTimer.stop()
        root.installingClient = false
        root.showNotification("Omagate", "Client installed. Finishing setup…", false)
        root.prepareSetup()
      }
    }
  }

  Process {
    id: prepareProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: prepareStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: prepareStderr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.preparingSetup = false
      if (exitCode === 0) {
        root.setupError = ""
        root.checkSetup()
        root.refresh()
        root.showNotification("Omagate", "Omagate setup complete", false)
      } else {
        var message = Model.bounded(prepareStderr.text || prepareStdout.text || "", 4096)
        root.setupError = root.elide(message || "Setup failed")
      }
    }
  }

  Process {
    id: whichProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) root.refresh()
      else {
        root.serviceAvailable = false
        root.lastError = "vpncmd was not found"
      }
    }
  }

  Process {
    id: accountsProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: accountsStdout
      waitForEnd: true
      onStreamFinished: root._accountsOutput = Model.bounded(text, 65536) || ""
    }
    stderr: StdioCollector {
      id: accountsStderr
      waitForEnd: true
      onStreamFinished: root._accountsError = Model.bounded(text, 4096) || ""
    }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = Model.bounded(accountsStdout.text || root._accountsOutput || "", 65536)
      var stderr = Model.bounded(accountsStderr.text || root._accountsError || "", 4096)
      if (exitCode === 0 && stdout !== null && stderr !== null) {
        root.serviceAvailable = true
        var parsedAccounts = Model.parseAccountList(stdout)
        for (var i = 0; i < parsedAccounts.length; i++) {
          var country = root.countryDetailsFor(parsedAccounts[i].name)
          parsedAccounts[i].country = country.label
          parsedAccounts[i].countryCode = country.code
          parsedAccounts[i].flag = country.flag
          if (parsedAccounts[i].name === "VPNGate_Direct") {
            var directNode = root.directConnectedNode
            if (!directNode && root.onlineNodes) {
              var sHost = (parsedAccounts[i].server || "").split(":")[0].trim()
              for (var j = 0; j < root.onlineNodes.length; j++) {
                if (root.onlineNodes[j].ip === sHost) {
                  directNode = root.onlineNodes[j]
                  root.directConnectedNode = directNode
                  break
                }
              }
            }
            if (directNode) {
              parsedAccounts[i].country = directNode.country || "VPN"
              parsedAccounts[i].countryCode = directNode.countryCode || ""
              parsedAccounts[i].flag = directNode.flag || "🏳"
            }
          }
        }
        var signature = root.accountSignature(parsedAccounts)
        if (signature !== root._accountsSignature || root.accounts.length !== parsedAccounts.length) {
          root.accounts = parsedAccounts
          root._accountsSignature = signature
        }
        root.choosePreferredAccount()
        if (root.usable && root.connectedAccount !== null) root.recordConnection(root.connectedAccount.name)
        if (root.lastError.indexOf("service") !== -1) root.lastError = ""
        // Optimism lasts until the tunnel is genuinely routed. Clearing it as
        // soon as a session appears would drop the switch back to off while the
        // address and default route are still being installed.
        if (root.desiredState === 1 && (root.usable || root.connectedAccount !== null)
            && (root.connectTargetName === ""
              || (root.connectedAccount !== null && root.connectedAccount.name === root.connectTargetName))) {
          root.desiredState = -1
          root.connectTargetName = ""
        }
        if (root.usable || root.connectedAccount !== null) {
          root.stopConnectionTimeout()
        }
        if (root.desiredState === 0 && !root.activeAccount) root.desiredState = -1
        else if (root.desiredState === 0 && root.activeAccount && !actionProcess.running) {
          root.disconnectVpn()
        }
        if (root.connectedAccount !== null || root.connectingAccount !== null || root.desiredState === 1 || (root.busy && root.actionKind === "connect")) {
          root.refreshNetwork()
        } else {
          root.tunnelAddress = ""
          root.hasVpnDefaultRoute = false
        }
      } else {
        root.serviceAvailable = false
        root.accounts = []
        root._accountsSignature = ""
        root.tunnelAddress = ""
        root.hasVpnDefaultRoute = false
        root.lastError = root.elide(stderr || stdout || "SoftEther client service is unavailable")
      }
    }
  }

  Process {
    id: addressProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: addressStdout
      waitForEnd: true
      onStreamFinished: root._addressOutput = Model.bounded(text, 32768) || ""
    }
    onExited: function(exitCode) {
      var stdout = Model.bounded(addressStdout.text || root._addressOutput || "", 32768)
      root.tunnelAddress = exitCode === 0 && stdout !== null
        ? Model.parseAddress(stdout) : ""
    }
  }

  Process {
    id: routeProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: routeStdout
      waitForEnd: true
      onStreamFinished: root._routeOutput = Model.bounded(text, 32768) || ""
    }
    onExited: function(exitCode) {
      var stdout = Model.bounded(routeStdout.text || root._routeOutput || "", 32768)
      root.hasVpnDefaultRoute = exitCode === 0 && stdout !== null
        && Model.hasDefaultRoute(stdout, root.adapterName)
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: actionStdout
      waitForEnd: true
      onStreamFinished: root._actionOutput = Model.bounded(text, 65536) || ""
    }
    stderr: StdioCollector {
      id: actionStderr
      waitForEnd: true
      onStreamFinished: root._actionError = Model.bounded(text, 4096) || ""
    }
    onExited: function(exitCode) {
      var stdout = Model.bounded(actionStdout.text || root._actionOutput || "", 65536)
      var stderr = Model.bounded(actionStderr.text || root._actionError || "", 4096)
      var next = root.connectAfterDisconnect
      var completedKind = root.actionKind
      root.actionKind = ""
      root.actionAccountName = ""
      root.connectAfterDisconnect = ""
      root.actionStatus = ""

      if (exitCode !== 0 || stdout === null || stderr === null) {
        root.stopConnectionTimeout()
        root.connectTargetName = ""
        if (root.desiredState === 0) {
          if (root.connectionTimedOut) {
            root.desiredState = -1
            root.lastError = "Connection timed out after 9 seconds"
            root.connectionTimedOut = false
          } else {
            root.lastError = ""
          }
          settleDesiredState.restart()
          delayedRefresh.restart()
          return
        }
        root.desiredState = -1
        root.lastError = stdout === null || stderr === null
          ? "SoftEther command output exceeded safe limits"
          : root.elide(stderr || stdout || "SoftEther command failed")
        if (completedKind === "connect") {
          root.showNotification("Omagate", root.lastError, true)
        }
        root.refresh()
        return
      }

      root.lastError = ""
      if (completedKind === "disconnect" && root.pendingDirectConnectNode) {
        var nodeToDirect = root.pendingDirectConnectNode
        root.pendingDirectConnectNode = null
        Qt.callLater(function() {
          root.startDirectOnlineProcess(nodeToDirect)
        })
        return
      }
      if (completedKind === "disconnect" && next !== "") {
        Qt.callLater(function() { root.runAction("connect", next, "") })
      } else {
        settleDesiredState.restart()
        delayedRefresh.restart()
      }
    }
  }

  Process {
    id: renameProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: renameStdout
      waitForEnd: true
      onStreamFinished: root._renameOutput = text || ""
    }
    stderr: StdioCollector {
      id: renameStderr
      waitForEnd: true
      onStreamFinished: root._renameError = text || ""
    }
    onExited: function(exitCode) {
      var oldName = root.renamingOldName
      var newName = root.renamingNewName
      root.renamingOldName = ""
      root.renamingNewName = ""
      var stdout = renameStdout.text || root._renameOutput || ""
      var stderr = renameStderr.text || root._renameError || ""

      if (exitCode !== 0) {
        root.lastError = root.elide(stderr || stdout || "Failed to rename account")
        root.refresh()
        return
      }

      root.lastError = ""
      if (root.selectedAccountName === oldName) {
        root.selectedAccountName = newName
        root.selectionRequested(newName)
      }
      root.accountRenamed(oldName, newName)
      root.refresh()
    }
  }

  Process {
    id: pickerProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: pickerStdout
      waitForEnd: true
      onStreamFinished: root._pickerOutput = text || ""
    }
    onExited: function(exitCode) {
      var output = pickerStdout.text || root._pickerOutput || ""
      if (exitCode !== 0 || !output || output.trim() === "") {
        return
      }
      var lines = output.split("\n")
      var files = []
      for (var i = 0; i < lines.length; i++) {
        var f = lines[i].trim()
        if (f.length > 0) files.push(f)
      }
      if (files.length > 0) {
        root.importFiles(files)
      }
    }
  }

  Process {
    id: importProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: importStdout
      waitForEnd: true
      onStreamFinished: root._importOutput = text || ""
    }
    stderr: StdioCollector {
      id: importStderr
      waitForEnd: true
      onStreamFinished: root._importError = text || ""
    }
    onExited: function(exitCode) {
      var stdout = (importStdout.text || root._importOutput || "").trim()
      var stderr = (importStderr.text || root._importError || "").trim()
      if (exitCode === 0) {
        root.lastError = ""
        root.refreshAccounts()
        root.showNotification("Omagate", stdout ? stdout : "Successfully imported VPN profile(s)", false)
        root.importCompleted(true, stdout)
      } else {
        root.lastError = root.elide(stderr || stdout || "Failed to import VPN profile")
        root.showNotification("Omagate", root.lastError, true)
        root.importCompleted(false, root.lastError)
      }
    }
  }

  Process {
    id: fetchOnlineProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: fetchOnlineStdout
      waitForEnd: true
      onStreamFinished: root._onlineOutput = text || ""
    }
    stderr: StdioCollector {
      id: fetchOnlineStderr
      waitForEnd: true
      onStreamFinished: root._onlineError = text || ""
    }
    onExited: function(exitCode) {
      var stdout = (fetchOnlineStdout.text || root._onlineOutput || "").trim()
      var stderr = (fetchOnlineStderr.text || root._onlineError || "").trim()
      if (exitCode === 0 && stdout.length > 0) {
        try {
          var parsed = JSON.parse(stdout)
          if (Array.isArray(parsed)) {
            var safeNodes = []
            for (var i = 0; i < parsed.length && safeNodes.length < 512; i++) {
              if (root.isEndpointNode(parsed[i])) safeNodes.push(parsed[i])
            }
            if (safeNodes.length === 0) {
              root.onlineError = "No usable VPN Gate nodes in the response"
              root.onlineNodesFetched(false, root.onlineError)
              return
            }
            root.onlineNodes = safeNodes
            root.onlineError = ""
            root.onlineNodesFetched(true, "")
            return
          }
        } catch (e) {
          root.onlineError = "Failed to parse VPN Gate data"
        }
      } else {
        root.onlineError = root.elide(stderr || stdout || "Failed to fetch VPN Gate nodes")
      }
      root.onlineNodesFetched(false, root.onlineError)
    }
  }

  Process {
    id: addOnlineProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: addOnlineStdout
      waitForEnd: true
      onStreamFinished: root._addOnlineOutput = text || ""
    }
    stderr: StdioCollector {
      id: addOnlineStderr
      waitForEnd: true
      onStreamFinished: root._addOnlineError = text || ""
    }
    onExited: function(exitCode) {
      var stdout = (addOnlineStdout.text || root._addOnlineOutput || "").trim()
      var stderr = (addOnlineStderr.text || root._addOnlineError || "").trim()
      if (exitCode === 0) {
        root.lastError = ""
        root.refreshAccounts()
        root.showNotification("Omagate", stdout ? stdout : "Added to saved nodes", false)
        root.onlineNodeAdded(true, "", stdout)
      } else {
        root.lastError = root.elide(stderr || stdout || "Failed to add VPN node")
        root.showNotification("Omagate", root.lastError, true)
        root.onlineNodeAdded(false, "", root.lastError)
      }
    }
  }

  Process {
    id: directOnlineProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: directOnlineStdout
      waitForEnd: true
      onStreamFinished: root._directOnlineOutput = text || ""
    }
    stderr: StdioCollector {
      id: directOnlineStderr
      waitForEnd: true
      onStreamFinished: root._directOnlineError = text || ""
    }
    onExited: function(exitCode) {
      var stdout = (directOnlineStdout.text || root._directOnlineOutput || "").trim()
      var stderr = (directOnlineStderr.text || root._directOnlineError || "").trim()
      if (exitCode === 0) {
        root.lastError = ""
        root.actionKind = ""
        root.actionAccountName = ""
        root.actionStatus = ""
        root.runAction("connect", "VPNGate_Direct", "")
      } else {
        root.stopConnectionTimeout()
        root.connectTargetName = ""
        root.actionKind = ""
        root.actionAccountName = ""
        root.actionStatus = ""
        root.desiredState = -1
        root.lastError = root.elide(stderr || stdout || "Failed to configure direct connection")
        root.showNotification("Omagate", root.lastError, true)
        root.refresh()
      }
    }
  }

  function showNotification(summary, body, isError) {
    var icon = isError ? "dialog-error" : "network-vpn"
    Quickshell.execDetached([
      "notify-send",
      "-a", "Omagate",
      "-i", icon,
      "-t", "2000",
      summary || "Omagate",
      body || ""
    ])
  }
}
