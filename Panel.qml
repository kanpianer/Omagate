import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "." as Local
import "Model.js" as Model

Panel {
  id: root

  moduleName: "io.github.kanpianer.omagate"
  ipcTarget: "io.github.kanpianer.omagate"
  manageIpc: false

  property int accountIndex: 0
  property bool cursorActive: false

  property string pluginVersion: ""
  readonly property string pluginVersionLabel: {
    var version = root.pluginVersion
    if (version === "") return ""
    return version.charAt(0).toLowerCase() === "v" ? version : "v" + version
  }

  property var customOrder: Model.asArray(root.settings ? root.settings.accountOrder : null)

  onSettingsChanged: {
    var nextOrder = Model.asArray(root.settings ? root.settings.accountOrder : null)
    if (nextOrder.length > 0) {
      root.customOrder = nextOrder
    }
  }



  readonly property var displayAccounts: Model.sortAccounts(vpn.savedAccounts, customOrder)

  readonly property var savedIpsMap: {
    var map = Object.create(null)
    var accounts = vpn.savedAccounts
    for (var i = 0; i < accounts.length; i++) {
      var s = accounts[i].server
      if (s) {
        var colon = s.indexOf(":")
        var host = (colon !== -1 ? s.substring(0, colon) : s).trim()
        if (host.length > 0) {
          map[host] = true
        }
      }
    }
    return map
  }

  property bool dragActive: false
  property int dragSourceIndex: -1
  property int dragTargetIndex: -1
  property real dragStartY: 0
  property real dragCurrentY: 0
  property bool suppressClick: false

  property string pendingAction: ""
  property var pendingAccount: null
  property string confirmMessage: ""
  property string confirmButtonText: "Connect"
  property string renameAccountTarget: ""

  property bool showOnlineNodes: false
  readonly property bool showSetup: vpn.setupRequired
  readonly property var setupSteps: [
    { label: "SoftEther VPN client", done: vpn.setupState.client === true },
    { label: "Client service enabled", done: vpn.setupState.serviceActive === true && vpn.setupState.serviceEnabled === true },
    { label: "Virtual adapter " + vpn.adapterName, done: vpn.setupState.adapterPresent === true },
    { label: "NetworkManager profile", done: vpn.setupState.profilePresent === true && vpn.setupState.profileMatches === true }
  ]
  property string selectedOnlineCountry: ""
  property string selectedOnlineCountryName: "All"
  property string selectedOnlineCountryFlag: ""
  property string onlineSortField: "speed"
  property bool onlineSortAsc: false
  property bool countryPopupOpen: false

  readonly property var countryList: Model.getCountryList(vpn.onlineNodes)
  readonly property string activeServerIp: {
    var acc = vpn.activeAccount
    if (!acc || !acc.server) return ""
    var s = acc.server
    var colon = s.indexOf(":")
    return (colon !== -1 ? s.substring(0, colon) : s).trim()
  }
  readonly property var filteredOnlineNodes: Model.filterAndSortOnlineNodes(
    vpn.onlineNodes, selectedOnlineCountry, onlineSortField, onlineSortAsc)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // The flag means the tunnel is usable (session, adapter address, default
  // route). A session that outlived its link falls back to the shield, whose
  // warning badge is what tells the user the connection dropped.
  readonly property bool isVpnConnected: vpn.connectedAccount !== null
  readonly property string selectedFlag: vpn.selectedAccount
    ? String(vpn.selectedAccount.flag || "🏳") : "🏳"
  readonly property string connectedFlag: {
    if (vpn.connectedAccount) {
      if (vpn.connectedAccount.name === "VPNGate_Direct" && vpn.directConnectedNode) {
        return String(vpn.directConnectedNode.flag || "🏳")
      }
      return String(vpn.connectedAccount.flag || "🏳")
    }
    return selectedFlag
  }
  readonly property color iconColor: {
    if (vpn.state === "error" || vpn.state === "warning") return urgent
    if (vpn.state === "off") return Qt.darker(barForeground, 1.55)
    return barForeground
  }

  function clampIndex() {
    if (root.displayAccounts.length === 0) accountIndex = 0
    else accountIndex = Math.max(0, Math.min(root.displayAccounts.length - 1, accountIndex))
  }

  function selectedRow() {
    if (root.displayAccounts.length === 0) return null
    clampIndex()
    return root.displayAccounts[accountIndex]
  }

  function moveCursor(delta) {
    if (root.displayAccounts.length === 0) return
    cursorActive = true
    accountIndex = Math.max(0, Math.min(root.displayAccounts.length - 1, accountIndex + delta))
    ensureRowVisible(accountIndex)
  }

  function ensureRowVisible(index) {
    var item = accountsRepeater.itemAt(index)
    if (!item) return
    var itemTop = accountsColumn.mapToItem(scrollColumn, 0, item.y).y
    var itemBottom = itemTop + item.height
    if (itemTop < flickable.contentY) {
      flickable.contentY = Math.max(0, itemTop)
    } else if (itemBottom > flickable.contentY + flickable.height) {
      flickable.contentY = Math.min(flickable.contentHeight - flickable.height, itemBottom - flickable.height)
    }
  }

  function locateConnectedAccount() {
    var active = vpn.connectedAccount || vpn.activeAccount
    if (!active || active.name === "VPNGate_Direct") return
    var targetName = active.name
    var list = root.displayAccounts
    for (var i = 0; i < list.length; i++) {
      if (list[i].name === targetName) {
        root.cursorActive = true
        root.accountIndex = i
        var item = accountsRepeater.itemAt(i)
        if (item) {
          var itemTop = accountsColumn.mapToItem(scrollColumn, 0, item.y).y
          var targetY = itemTop - (flickable.height - item.height) / 2
          var maxY = Math.max(0, flickable.contentHeight - flickable.height)
          flickableScrollAnim.stop()
          flickableScrollAnim.from = flickable.contentY
          flickableScrollAnim.to = Math.max(0, Math.min(maxY, targetY))
          flickableScrollAnim.restart()
        }
        break
      }
    }
  }

  function locateConnectedOnlineNode() {
    if (!root.activeServerIp) return
    var foundIndex = -1
    for (var i = 0; i < root.filteredOnlineNodes.length; i++) {
      var n = root.filteredOnlineNodes[i]
      if (n.ip === root.activeServerIp || n.hostname === root.activeServerIp) {
        foundIndex = i
        break
      }
    }
    if (foundIndex < 0 && root.selectedOnlineCountry !== "") {
      root.selectedOnlineCountry = ""
      root.selectedOnlineCountryName = "All"
      root.selectedOnlineCountryFlag = ""
      for (var j = 0; j < root.filteredOnlineNodes.length; j++) {
        var node = root.filteredOnlineNodes[j]
        if (node.ip === root.activeServerIp || node.hostname === root.activeServerIp) {
          foundIndex = j
          break
        }
      }
    }
    if (foundIndex >= 0) {
      var item = onlineNodesRepeater.itemAt(foundIndex)
      if (item) {
        var itemTop = onlineAccountsColumn.mapToItem(scrollColumn, 0, item.y).y
        var targetY = itemTop - (flickable.height - item.height) / 2
        var maxY = Math.max(0, flickable.contentHeight - flickable.height)
        flickableScrollAnim.stop()
        flickableScrollAnim.from = flickable.contentY
        flickableScrollAnim.to = Math.max(0, Math.min(maxY, targetY))
        flickableScrollAnim.restart()
      } else {
        flickableScrollAnim.stop()
        flickableScrollAnim.from = flickable.contentY
        flickableScrollAnim.to = 0
        flickableScrollAnim.restart()
      }
    }
  }


  function activateCursor() {
    if (renameDialog.opened || vpn.renaming || vpn.busy) return
    var account = selectedRow()
    if (account) chooseAccount(account)
  }

  function requestToggleVpn() {
    if (confirmDialog.opened) {
      confirmDialog.opened = false
      pendingAction = ""
      pendingAccount = null
    }
    if (!vpn.settingsValid || !vpn.serviceAvailable) return
    if (root.displayAccounts.length === 0 && !vpn.directConnectedNode && !vpn.activeAccount) return
    if ((vpn.busy && vpn.actionKind === "disconnect") || vpn.desiredState === 0) return

    var isConnectingOrConnected = vpn.active
      || vpn.connectedAccount !== null
      || vpn.connectingAccount !== null
      || (vpn.busy && vpn.actionKind === "connect")
      || vpn.desiredState === 1

    if (isConnectingOrConnected) {
      vpn.disconnectVpn()
    } else {
      vpn.connectVpn()
    }
  }

  function chooseAccount(account) {
    if (!account || renameDialog.opened || vpn.renaming || vpn.busy) return
    var isCurrent = (vpn.connectedAccount && vpn.connectedAccount.name === account.name)
      || (vpn.activeAccount && vpn.activeAccount.name === account.name)
    if (isCurrent) {
      pendingAction = "disconnect"
      pendingAccount = null
      confirmMessage = "Disconnect from VPN?"
      confirmButtonText = "Disconnect"
    } else if (vpn.active || vpn.connectedAccount !== null || vpn.activeAccount !== null) {
      pendingAction = "connect_account"
      pendingAccount = account
      confirmMessage = "Disconnect current VPN and connect to \"" + account.name + "\"?"
      confirmButtonText = "Connect"
    } else {
      pendingAction = "connect_account"
      pendingAccount = account
      confirmMessage = "Connect to VPN node \"" + account.name + "\"?"
      confirmButtonText = "Connect"
    }
    confirmDialog.selectedIndex = 1
    confirmDialog.opened = true
  }

  function isNodeSaved(ip) {
    if (!ip) return false
    return root.savedIpsMap[String(ip).trim()] === true
  }

  function chooseOnlineNode(node) {
    if (!node || !node.name) return
    var isActive = root.activeServerIp !== "" && (node.ip === root.activeServerIp || node.hostname === root.activeServerIp)
    if (isActive) {
      pendingAction = "disconnect"
      pendingAccount = null
      confirmMessage = "Disconnect from VPN?"
      confirmButtonText = "Disconnect"
    } else if (vpn.active || vpn.connectedAccount !== null || vpn.activeAccount !== null) {
      pendingAction = "connect_online"
      pendingAccount = node
      confirmMessage = "Disconnect current VPN and connect to VPN Gate node \"" + node.name + "\" (" + node.ip + ")?"
      confirmButtonText = "Connect"
    } else {
      pendingAction = "connect_online"
      pendingAccount = node
      confirmMessage = "Connect to VPN Gate node \"" + node.name + "\" (" + node.ip + ")?"
      confirmButtonText = "Connect"
    }
    confirmDialog.selectedIndex = 1
    confirmDialog.opened = true
  }

  function requestDeleteAccount(account) {
    if (!account || !account.name || vpn.busy) return
    pendingAction = "delete_account"
    pendingAccount = account
    confirmMessage = "Delete VPN node \"" + account.name + "\"?"
    confirmButtonText = "Delete"
    confirmDialog.selectedIndex = 1
    confirmDialog.opened = true
  }

  function requestRenameAccount(account) {
    if (!account || !account.name || vpn.busy) return
    var existing = []
    for (var i = 0; i < vpn.accounts.length; i++) {
      existing.push(vpn.accounts[i].name)
    }
    renameAccountTarget = account.name
    renameDialog.open(account.name, existing)
  }

  function onAccountRenamed(oldName, newName) {
    if (root.customOrder && root.customOrder.length > 0) {
      var next = []
      for (var i = 0; i < root.customOrder.length; i++) {
        if (root.customOrder[i] === oldName) {
          next.push(newName)
        } else {
          next.push(root.customOrder[i])
        }
      }
      persistAccountOrder(next)
    }
  }

  function removeAccountFromOrder(name) {
    var current = Model.asArray(customOrder)
    if (!name || current.length === 0) return
    var newOrder = []
    for (var i = 0; i < current.length; i++) {
      if (current[i] !== name) {
        newOrder.push(current[i])
      }
    }
    if (newOrder.length !== current.length) {
      persistAccountOrder(newOrder)
    }
  }

  function calculateDropIndex(yPos) {
    var count = accountsRepeater.count
    if (count <= 1) return 0
    for (var i = 0; i < count; i++) {
      var item = accountsRepeater.itemAt(i)
      if (item) {
        var itemMidY = item.y + item.height / 2
        if (yPos < itemMidY) return i
      }
    }
    return count - 1
  }

  function startDragAccount(index, yPos) {
    if (root.displayAccounts.length <= 1 || vpn.busy) return
    root.dragActive = true
    root.dragSourceIndex = index
    root.dragTargetIndex = index
    root.dragStartY = yPos
    root.dragCurrentY = yPos
    root.suppressClick = false
  }

  function updateDragAccount(yPos) {
    if (!root.dragActive) return
    root.dragCurrentY = yPos
    root.dragTargetIndex = calculateDropIndex(yPos)

    if (flickable.contentHeight > flickable.height) {
      var yInView = accountsColumn.mapToItem(flickable, 0, yPos).y
      if (yInView < Style.space(30) && flickable.contentY > 0) {
        flickable.contentY = Math.max(0, flickable.contentY - Style.space(8))
      } else if (yInView > flickable.height - Style.space(30) && flickable.contentY < flickable.contentHeight - flickable.height) {
        flickable.contentY = Math.min(flickable.contentHeight - flickable.height, flickable.contentY + Style.space(8))
      }
    }
  }

  function finishDragAccount() {
    if (!root.dragActive) return
    var src = root.dragSourceIndex
    var tgt = root.dragTargetIndex
    root.dragActive = false
    root.suppressClick = true

    if (src !== tgt && src >= 0 && tgt >= 0) {
      var currentList = Model.asArray(root.displayAccounts)
      var item = currentList.splice(src, 1)[0]
      currentList.splice(tgt, 0, item)

      var newOrder = []
      for (var i = 0; i < currentList.length; i++) {
        if (currentList[i] && currentList[i].name) {
          newOrder.push(currentList[i].name)
        }
      }
      persistAccountOrder(newOrder)
    }
  }

  function cancelDragAccount() {
    root.dragActive = false
    root.suppressClick = true
  }

  function persistAccountOrder(order) {
    var validOrder = Model.asArray(order)
    customOrder = validOrder
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.accountOrder = validOrder
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function persistSelection(accountName) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.accountName = accountName
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Remembered separately from accountName: the header follows the node that
  // actually came up, while accountName stays the last explicit selection.
  function persistLastConnected(accountName) {
    var name = String(accountName || "")
    if (name === "" || name === "VPNGate_Direct") return
    if (root.settings && String(root.settings.lastConnectedAccount || "") === name) return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.lastConnectedAccount = name
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    var savedOrder = Model.asArray(root.settings ? root.settings.accountOrder : null)
    if (savedOrder.length > 0) {
      root.customOrder = savedOrder
    }
    cursorActive = false
    confirmDialog.opened = false
    renameDialog.close()
    countryPopupOpen = false
    dragActive = false
    pendingAction = ""
    pendingAccount = null
    flickable.contentY = 0
    vpn.refresh()
    vpn.checkSetup()
    if (showOnlineNodes && vpn.onlineNodes.length === 0 && !vpn.fetchingOnline) {
      vpn.fetchOnlineNodes()
    }
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
    })
  } else {
    confirmDialog.opened = false
    renameDialog.close()
    countryPopupOpen = false
    dragActive = false
    pendingAction = ""
    pendingAccount = null
  }

  // The shell hands bar widgets only the bar, module name, and settings, so the
  // version comes from the installed manifest itself. Watching the file also
  // means the badge shows the new number immediately after an update, even
  // when the running QML is still the cached pre-update copy.
  FileView {
    id: manifestFile
    path: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.moduleName + "/manifest.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.pluginVersion = Model.pluginVersion(text())
    onFileChanged: reload()
    onLoadFailed: root.pluginVersion = ""
  }

  Service {
    id: vpn
    settings: root.settings
    panelOpen: root.opened
    onSelectionRequested: function(accountName) { root.persistSelection(accountName) }
  }

  Connections {
    target: vpn
    function onAccountsChanged() { root.clampIndex() }
    function onConnectionRecorded(accountName) { root.persistLastConnected(accountName) }
    function onAccountRenamed(oldName, newName) { root.onAccountRenamed(oldName, newName) }
    function onImportCompleted(success, message) {
      if (success) {
        root.open()
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function togglePanel(): void { root.toggle() }
    function toggleVpn(): string { vpn.toggle(); return "ok" }
    function refresh(): string { vpn.refresh(); return "ok" }
    function status(): string { return vpn.statusText }
    function version(): string { return root.pluginVersionLabel }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.opened
    tooltipText: vpn.tooltipText

    onPressed: function(b) {
      if (b === Qt.MiddleButton) {
        vpn.refresh()
        return
      }
      if (root.opened) {
        root.close()
      } else {
        root.open()
      }
    }

    iconComponent: Component {
      Item {
        anchors.fill: parent

        ShieldIcon {
          visible: !root.isVpnConnected
          anchors.centerIn: parent
          iconSize: Style.space(13)
          color: root.iconColor
          badgeColor: root.urgent
          state: vpn.state
          pulsing: vpn.connectAnimationActive
        }

        Text {
          visible: root.isVpnConnected
          anchors.centerIn: parent
          text: root.connectedFlag
          textFormat: Text.PlainText
          color: root.foreground
          font.family: "Noto Color Emoji"
          font.pixelSize: Style.space(13)
        }
      }
    }

  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(454))
    contentHeight: panel.fittedContentHeight(headerColumn.implicitHeight + (scrollColumn.implicitHeight > 0 ? flickable.anchors.topMargin + scrollColumn.implicitHeight : 0) + (importFooter ? importFooter.height + flickable.anchors.bottomMargin : Style.space(45)), Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: renameDialog.opened || vpn.renaming || vpn.busy
      onMoveRequested: function(dx, dy) {
        if (confirmDialog.opened) {
          confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: {
        if (confirmDialog.opened) {
          if (confirmDialog.selectedIndex === 0) confirmDialog.canceled()
          else confirmDialog.confirmed()
          return
        }
        root.activateCursor()
      }
      onDeleteRequested: {
        if (confirmDialog.opened || renameDialog.opened) return
        var row = root.selectedRow()
        if (row) root.requestDeleteAccount(row)
      }
      onCloseRequested: {
        if (renameDialog.opened) {
          renameDialog.close()
          return
        }
        if (root.countryPopupOpen) {
          root.countryPopupOpen = false
          return
        }
        if (root.dragActive) {
          root.cancelDragAccount()
          return
        }
        if (confirmDialog.opened) {
          confirmDialog.canceled()
          return
        }
        root.close()
      }
      onTabRequested: function(direction) {
        if (confirmDialog.opened) {
          confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        root.switchPanel(direction)
      }
      onTextKey: function(text) {
        if (confirmDialog.opened || root.showSetup) return
        if (text === "r" || text === "R") vpn.refresh()
        else if (text === "t" || text === "T") root.requestToggleVpn()
        else if (text === "d" || text === "D") {
          var row = root.selectedRow()
          if (row) root.requestDeleteAccount(row)
        } else if (text === "i" || text === "I") {
          if (!vpn.busy && !vpn.importing && vpn.serviceAvailable) {
            root.close()
            vpn.openImportDialog()
          }
        }
      }

      Column {
        id: headerColumn
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        RowLayout {
          width: parent.width
          spacing: Style.space(12)

          VpnSwitch {
            id: powerSwitch
            checked: vpn.active
              || vpn.connectedAccount !== null
              || vpn.connectingAccount !== null
              || (vpn.busy && vpn.actionKind === "connect")
              || vpn.desiredState === 1
            busy: !vpn.serviceAvailable
              || (root.displayAccounts.length === 0 && !vpn.directConnectedNode && !vpn.activeAccount)
              || (vpn.selectedAccount === null && vpn.activeAccount === null)
              || vpn.desiredState === 0
              || (vpn.busy && vpn.actionKind !== "connect")
              || vpn.importing
            foreground: root.foreground
            accent: Color.accent
            Layout.alignment: Qt.AlignVCenter
            Layout.leftMargin: Style.space(2)
            onToggled: root.requestToggleVpn()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: !vpn.serviceAvailable ? "SoftEther client service is stopped"
                : (root.displayAccounts.length === 0 && !vpn.directConnectedNode && !vpn.activeAccount ? "No imported VPN profiles"
                : (vpn.selectedAccount === null && vpn.activeAccount === null ? "Select a node first"
                : (powerSwitch.checked ? "Disconnect VPN" : "Connect to VPN")))
              fontFamily: root.fontFamily
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            Text {
              Layout.fillWidth: true
              text: {
                if (!vpn.headerTarget) return "🏳  No node selected"
                return (vpn.headerFlag || "🏳") + "  " + vpn.headerName
              }
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              Layout.fillWidth: true
              text: vpn.statusText.toUpperCase()
              textFormat: Text.PlainText
              color: vpn.state === "error" || vpn.state === "warning" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.0
              elide: Text.ElideRight
            }
          }

          Text {
            visible: root.pluginVersionLabel !== ""
            text: root.pluginVersionLabel
            textFormat: Text.PlainText
            color: root.dim
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.5
            Layout.alignment: Qt.AlignTop | Qt.AlignRight
            Layout.topMargin: Style.space(2)
            Layout.leftMargin: Style.space(4)
          }
        }

        Text {
          visible: vpn.lastError !== ""
          width: parent.width
          text: vpn.lastError
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator {
          foreground: root.foreground
        }

        RowLayout {
          id: savedFixedHeader
          visible: !root.showOnlineNodes && !root.showSetup
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "SAVED NODES"
            foreground: root.foreground
            fontFamily: root.fontFamily
            Layout.alignment: Qt.AlignVCenter
          }

          PanelActionButton {
            id: locateSavedNodeBtn
            enabled: (vpn.connectedAccount !== null || vpn.activeAccount !== null) && root.displayAccounts.length > 0 && !(vpn.activeAccount && vpn.activeAccount.name === "VPNGate_Direct")
            opacity: enabled ? 1.0 : 0.35
            iconText: "󰍎"
            tooltipText: enabled ? "Locate connected node" : (vpn.activeAccount && vpn.activeAccount.name === "VPNGate_Direct" ? "Connected to online node (not saved)" : "No VPN node connected")
            foreground: root.dim
            hoverColor: Color.accent
            fontFamily: root.fontFamily
            Layout.alignment: Qt.AlignVCenter
            onClicked: root.locateConnectedAccount()
          }

          Item {
            Layout.fillWidth: true
          }
        }

        Column {
          id: onlineFixedHeader
          visible: root.showOnlineNodes && !root.showSetup
          width: parent.width
          spacing: Style.space(8)

          RowLayout {
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "VPN GATE NODES" + (root.filteredOnlineNodes.length > 0 ? " (" + root.filteredOnlineNodes.length + ")" : "")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.0
              Layout.alignment: Qt.AlignVCenter
            }

            PanelActionButton {
              id: locateOnlineNodeBtn
              enabled: (vpn.connectedAccount !== null || vpn.activeAccount !== null) && root.activeServerIp !== ""
              opacity: enabled ? 1.0 : 0.35
              iconText: "󰍎"
              tooltipText: enabled ? "Locate connected node" : "No VPN node connected"
              foreground: root.dim
              hoverColor: Color.accent
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.locateConnectedOnlineNode()
            }

            Item {
              Layout.fillWidth: true
            }

            PanelActionButton {
              id: refreshOnlineBtn
              iconText: "󰑐"
              tooltipText: "Refresh online nodes"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              enabled: !vpn.fetchingOnline
              Layout.alignment: Qt.AlignVCenter
              onClicked: vpn.fetchOnlineNodes(true)

              NumberAnimation on rotation {
                running: vpn.fetchingOnline
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
                onRunningChanged: if (!running) refreshOnlineBtn.rotation = 0
              }
            }
          }

          Row {
            id: filterButtonsRow
            width: parent.width
            spacing: Style.space(5)
            readonly property real buttonWidth: Math.floor((width - spacing * 4) / 5)

            BorderSurface {
              id: countryFilterBtn
              width: filterButtonsRow.buttonWidth
              height: Style.space(26)
              color: root.selectedOnlineCountry !== "" ? Util.alpha(Color.accent, 0.15) : "transparent"
              borderSpec: Border.flat(root.selectedOnlineCountry !== "" ? Color.accent : Util.alpha(root.foreground, 0.25), Style.normalBorderWidth)
              radius: Style.cornerRadius

              RowLayout {
                anchors.centerIn: parent
                spacing: Style.space(3)

                Text {
                  text: root.selectedOnlineCountry === "" ? "Country" : (root.selectedOnlineCountryFlag + " " + root.selectedOnlineCountry)
                  color: root.selectedOnlineCountry !== "" ? Color.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: root.selectedOnlineCountry !== ""
                  elide: Text.ElideRight
                }

                Text {
                  text: root.countryPopupOpen ? "▴" : "▾"
                  color: root.selectedOnlineCountry !== "" ? Color.accent : root.dim
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.countryPopupOpen = !root.countryPopupOpen
              }
            }

            BorderSurface {
              id: speedFilterBtn
              width: filterButtonsRow.buttonWidth
              height: Style.space(26)
              color: root.onlineSortField === "speed" ? Util.alpha(Color.accent, 0.15) : "transparent"
              borderSpec: Border.flat(root.onlineSortField === "speed" ? Color.accent : Util.alpha(root.foreground, 0.25), Style.normalBorderWidth)
              radius: Style.cornerRadius

              Text {
                anchors.centerIn: parent
                text: "Speed" + (root.onlineSortField === "speed" ? (root.onlineSortAsc ? " ▲" : " ▼") : "")
                color: root.onlineSortField === "speed" ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.onlineSortField === "speed"
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.onlineSortField === "speed") {
                    root.onlineSortAsc = !root.onlineSortAsc
                  } else {
                    root.onlineSortField = "speed"
                    root.onlineSortAsc = false
                  }
                }
              }
            }

            BorderSurface {
              id: sessionsFilterBtn
              width: filterButtonsRow.buttonWidth
              height: Style.space(26)
              color: root.onlineSortField === "sessions" ? Util.alpha(Color.accent, 0.15) : "transparent"
              borderSpec: Border.flat(root.onlineSortField === "sessions" ? Color.accent : Util.alpha(root.foreground, 0.25), Style.normalBorderWidth)
              radius: Style.cornerRadius

              Text {
                anchors.centerIn: parent
                text: "Sessions" + (root.onlineSortField === "sessions" ? (root.onlineSortAsc ? " ▲" : " ▼") : "")
                color: root.onlineSortField === "sessions" ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.onlineSortField === "sessions"
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.onlineSortField === "sessions") {
                    root.onlineSortAsc = !root.onlineSortAsc
                  } else {
                    root.onlineSortField = "sessions"
                    root.onlineSortAsc = false
                  }
                }
              }
            }

            BorderSurface {
              id: uptimeFilterBtn
              width: filterButtonsRow.buttonWidth
              height: Style.space(26)
              color: root.onlineSortField === "uptime" ? Util.alpha(Color.accent, 0.15) : "transparent"
              borderSpec: Border.flat(root.onlineSortField === "uptime" ? Color.accent : Util.alpha(root.foreground, 0.25), Style.normalBorderWidth)
              radius: Style.cornerRadius

              Text {
                anchors.centerIn: parent
                text: "Uptime" + (root.onlineSortField === "uptime" ? (root.onlineSortAsc ? " ▲" : " ▼") : "")
                color: root.onlineSortField === "uptime" ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.onlineSortField === "uptime"
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.onlineSortField === "uptime") {
                    root.onlineSortAsc = !root.onlineSortAsc
                  } else {
                    root.onlineSortField = "uptime"
                    root.onlineSortAsc = false
                  }
                }
              }
            }

            BorderSurface {
              id: pingFilterBtn
              width: filterButtonsRow.buttonWidth
              height: Style.space(26)
              color: root.onlineSortField === "ping" ? Util.alpha(Color.accent, 0.15) : "transparent"
              borderSpec: Border.flat(root.onlineSortField === "ping" ? Color.accent : Util.alpha(root.foreground, 0.25), Style.normalBorderWidth)
              radius: Style.cornerRadius

              Text {
                anchors.centerIn: parent
                text: "Ping" + (root.onlineSortField === "ping" ? (root.onlineSortAsc ? " ▲" : " ▼") : "")
                color: root.onlineSortField === "ping" ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.onlineSortField === "ping"
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.onlineSortField === "ping") {
                    root.onlineSortAsc = !root.onlineSortAsc
                  } else {
                    root.onlineSortField = "ping"
                    root.onlineSortAsc = true
                  }
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }
        }
      }

      Flickable {
        id: flickable
        anchors.top: headerColumn.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: importFooter.top
        anchors.bottomMargin: Style.space(8)
        contentWidth: width
        contentHeight: scrollColumn.implicitHeight
        contentX: 0
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height && !root.dragActive
        onContentXChanged: if (contentX !== 0) contentX = 0
        onMovementStarted: flickableScrollAnim.stop()

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        NumberAnimation {
          id: flickableScrollAnim
          target: flickable
          property: "contentY"
          duration: 200
          easing.type: Easing.OutCubic
        }

        Column {
          id: scrollColumn
          width: flickable.width
          spacing: Style.space(12)

          Column {
            id: setupView
            visible: root.showSetup
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: "GET STARTED"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.0
            }

            Text {
              width: parent.width
              text: vpn.setupState.client === true
                ? "SoftEther needs a one-time setup. The plugin will start its service, create the virtual adapter, and add the NetworkManager profile."
                : "SoftEther VPN Client is missing. Install it once from the AUR; a terminal will open for your password."
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.setupSteps

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Text {
                  text: modelData.done ? "✓" : "○"
                  color: modelData.done ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: modelData.done
                }

                Text {
                  text: modelData.label
                  color: modelData.done ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width - Style.space(24)
                }
              }
            }

            Text {
              visible: vpn.setupError !== ""
              width: parent.width
              text: vpn.setupError
              textFormat: Text.PlainText
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: vpn.checkingSetup || vpn.preparingSetup || vpn.installingClient
              width: parent.width
              text: vpn.installingClient ? "Installing in the terminal…"
                : (vpn.preparingSetup ? "Setting things up…" : "Checking prerequisites…")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          Column {
            id: localNodesView
            visible: !root.showSetup && !root.showOnlineNodes
            width: parent.width
            spacing: Style.space(12)

            Text {
              visible: vpn.serviceAvailable && vpn.accounts.length === 0
              width: parent.width
              text: "No saved VPN profiles. Import a .vpn file or select from online nodes."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !vpn.serviceAvailable
              width: parent.width
              text: "Start the softethervpn-client service to load VPN profiles."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Column {
              id: accountsColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                id: accountsRepeater
                model: root.displayAccounts

                CursorSurface {
                  id: accountRow
                  required property var modelData
                  required property int index
                  property var account: modelData
                  readonly property bool selectedAccount: vpn.selectedAccountName === account.name
                  readonly property bool connectedAccount: account.statusKind === "connected" || account.statusKind === "connecting"
                  readonly property bool isConnecting: {
                    if (account.statusKind === "connecting") return true
                    if (vpn.connectingAccount && vpn.connectingAccount.name === account.name) return true
                    if (vpn.busy && vpn.actionKind === "connect" && vpn.actionAccountName === account.name) return true
                    if (vpn.state === "connecting" && vpn.activeAccount && vpn.activeAccount.name === account.name) return true
                    return false
                  }
                  readonly property bool isDragging: root.dragActive && root.dragSourceIndex === index
                  property bool actionsHovered: false
                  readonly property bool rowHovered: (rowMouse.containsMouse || actionsHovered) && !root.dragActive

                  width: parent.width
                  implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
                  hasCursor: (rowHovered && !selectedAccount) || (root.cursorActive && root.accountIndex === index) || isDragging
                  current: selectedAccount || isDragging || isConnecting
                  foreground: root.foreground
                  z: isDragging ? 100 : 1
                  scale: isDragging ? 1.02 : 1.0

                  Behavior on scale { NumberAnimation { duration: 100 } }

                  transform: Translate {
                    y: {
                      if (!root.dragActive) return 0
                      if (accountRow.isDragging) {
                        return root.dragCurrentY - root.dragStartY
                      }
                      var src = root.dragSourceIndex
                      var tgt = root.dragTargetIndex
                      if (src === tgt) return 0

                      var draggedItem = accountsRepeater.itemAt(src)
                      var moveDistance = (draggedItem ? draggedItem.height : accountRow.height) + accountsColumn.spacing

                      if (src < tgt) {
                        if (accountRow.index > src && accountRow.index <= tgt) return -moveDistance
                      } else if (src > tgt) {
                        if (accountRow.index >= tgt && accountRow.index < src) return moveDistance
                      }
                      return 0
                    }

                    Behavior on y {
                      enabled: !accountRow.isDragging && root.dragActive
                      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                    }
                  }

                  MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: !root.dragActive
                    enabled: !vpn.busy
                    cursorShape: root.dragActive ? Qt.ClosedHandCursor : (enabled ? Qt.PointingHandCursor : Qt.ArrowCursor)
                    pressAndHoldInterval: 300

                    onEntered: {
                      if (!root.dragActive) {
                        root.cursorActive = false
                        root.accountIndex = accountRow.index
                      }
                    }

                    onExited: {
                      if (!root.dragActive) {
                        root.cursorActive = false
                      }
                    }

                    onPressAndHold: function(mouse) {
                      if (vpn.busy || root.displayAccounts.length <= 1) return
                      var mappedY = rowMouse.mapToItem(accountsColumn, 0, mouse.y).y
                      root.startDragAccount(accountRow.index, mappedY)
                    }

                    onPositionChanged: function(mouse) {
                      if (root.dragActive && root.dragSourceIndex === accountRow.index) {
                        var mappedY = rowMouse.mapToItem(accountsColumn, 0, mouse.y).y
                        root.updateDragAccount(mappedY)
                      }
                    }

                    onReleased: function(mouse) {
                      if (root.dragActive && root.dragSourceIndex === accountRow.index) {
                        root.finishDragAccount()
                      }
                    }

                    onCanceled: {
                      if (root.dragActive && root.dragSourceIndex === accountRow.index) {
                        root.cancelDragAccount()
                      }
                    }

                    onClicked: {
                      if (root.suppressClick) {
                        root.suppressClick = false
                        return
                      }
                      root.chooseAccount(accountRow.account)
                    }
                  }

                  RowLayout {
                    id: rowContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(8)

                    Rectangle {
                      id: accountStatusDot
                      width: Style.space(7)
                      height: width
                      radius: width / 2
                      color: (accountRow.connectedAccount || accountRow.isConnecting) ? root.foreground : root.dim
                      opacity: accountRow.isConnecting ? accountBreatheAnim.breatheOpacity : (accountRow.connectedAccount ? 1.0 : 0.35)
                      scale: accountRow.isConnecting ? accountBreatheAnim.breatheScale : 1.0
                      Layout.alignment: Qt.AlignVCenter

                      Item {
                        id: accountBreatheAnim
                        property real breatheOpacity: 1.0
                        property real breatheScale: 1.0

                        SequentialAnimation {
                          running: accountRow.isConnecting
                          loops: Animation.Infinite
                          onRunningChanged: {
                            if (!running) {
                              accountBreatheAnim.breatheOpacity = 1.0
                              accountBreatheAnim.breatheScale = 1.0
                            }
                          }
                          ParallelAnimation {
                            NumberAnimation { target: accountBreatheAnim; property: "breatheOpacity"; from: 1.0; to: 0.25; duration: 650; easing.type: Easing.InOutSine }
                            NumberAnimation { target: accountBreatheAnim; property: "breatheScale"; from: 1.0; to: 1.35; duration: 650; easing.type: Easing.InOutSine }
                          }
                          ParallelAnimation {
                            NumberAnimation { target: accountBreatheAnim; property: "breatheOpacity"; from: 0.25; to: 1.0; duration: 650; easing.type: Easing.InOutSine }
                            NumberAnimation { target: accountBreatheAnim; property: "breatheScale"; from: 1.35; to: 1.0; duration: 650; easing.type: Easing.InOutSine }
                          }
                        }
                      }
                    }

                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(1)

                      Text {
                        Layout.fillWidth: true
                        text: String(accountRow.account.flag || "🏳") + "  " + (accountRow.account.name || accountRow.account.country)
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: accountRow.selectedAccount
                        elide: Text.ElideRight
                      }

                      Text {
                        Layout.fillWidth: true
                        text: (accountRow.account.statusKind === "connected" ? "Connected · "
                          : (accountRow.account.statusKind === "connecting" ? "Connecting · " : ""))
                          + (accountRow.account.country && accountRow.account.country !== "Unknown" ? accountRow.account.country + " · " : "")
                          + accountRow.account.server
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    PanelActionButton {
                      id: renameButton
                      visible: !root.dragActive
                      enabled: !vpn.busy
                      iconText: "󰏫"
                      tooltipText: "Rename node"
                      foreground: root.dim
                      hoverColor: root.foreground
                      fontFamily: root.fontFamily
                      Layout.alignment: Qt.AlignVCenter
                      onHovered: function(isHovered) {
                        accountRow.actionsHovered = isHovered
                      }
                      onClicked: root.requestRenameAccount(accountRow.account)
                    }

                    PanelActionButton {
                      id: deleteButton
                      visible: !root.dragActive
                      enabled: !vpn.busy
                      iconText: "󰅙"
                      tooltipText: "Delete node"
                      foreground: root.dim
                      hoverColor: root.urgent
                      fontFamily: root.fontFamily
                      Layout.alignment: Qt.AlignVCenter
                      onHovered: function(isHovered) {
                        accountRow.actionsHovered = isHovered
                      }
                      onClicked: root.requestDeleteAccount(accountRow.account)
                    }
                  }
                }
              }
            }
          }

          Column {
            id: onlineNodesView
            visible: !root.showSetup && root.showOnlineNodes
            width: parent.width
            spacing: Style.space(8)


            Text {
              visible: vpn.fetchingOnline
              width: parent.width
              text: "Loading VPN Gate nodes…"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: !vpn.fetchingOnline && vpn.onlineError !== ""
              width: parent.width
              text: vpn.onlineError + ". Click refresh to retry."
              textFormat: Text.PlainText
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: !vpn.fetchingOnline && vpn.onlineError === "" && vpn.onlineNodes.length === 0
              width: parent.width
              text: "No VPN Gate nodes loaded. Click refresh to fetch."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: !vpn.fetchingOnline && vpn.onlineNodes.length > 0 && root.filteredOnlineNodes.length === 0
              width: parent.width
              text: "No nodes match the selected country filter."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: onlineAccountsColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                id: onlineNodesRepeater
                model: root.filteredOnlineNodes

                CursorSurface {
                  id: onlineRow
                  required property var modelData
                  required property int index
                  property var node: modelData
                  readonly property bool isNodeActive: root.activeServerIp !== "" && (node.ip === root.activeServerIp || node.hostname === root.activeServerIp)
                  readonly property bool isThisNode: (root.activeServerIp !== "" && (node.ip === root.activeServerIp || node.hostname === root.activeServerIp))
                    || (vpn.directConnectedNode && (vpn.directConnectedNode.ip === node.ip || (node.hostname && vpn.directConnectedNode.hostname === node.hostname)))
                  readonly property bool isConnecting: isThisNode && (
                    vpn.state === "connecting"
                    || (vpn.busy && vpn.actionKind === "connect")
                    || vpn.connectingAccount !== null
                    || (vpn.desiredState === 1 && !root.isVpnConnected)
                  )
                  readonly property bool alreadySaved: root.savedIpsMap[node.ip] === true
                  property bool actionHovered: false
                  readonly property bool onlineHovered: onlineMouse.containsMouse || actionHovered

                  width: parent.width
                  implicitHeight: onlineRowContent.implicitHeight + Style.spacing.rowPaddingX
                  foreground: root.foreground
                  hasCursor: onlineHovered && !isNodeActive && !isConnecting
                  current: isNodeActive || isConnecting

                  MouseArea {
                    id: onlineMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.chooseOnlineNode(onlineRow.node)
                  }

                  RowLayout {
                    id: onlineRowContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(8)

                    Rectangle {
                      id: onlineStatusDot
                      width: Style.space(7)
                      height: width
                      radius: width / 2
                      color: (onlineRow.isNodeActive || onlineRow.isConnecting) ? root.foreground : root.dim
                      opacity: onlineRow.isConnecting ? onlineBreatheAnim.breatheOpacity : (onlineRow.isNodeActive ? 1.0 : 0.35)
                      scale: onlineRow.isConnecting ? onlineBreatheAnim.breatheScale : 1.0
                      Layout.alignment: Qt.AlignVCenter

                      Item {
                        id: onlineBreatheAnim
                        property real breatheOpacity: 1.0
                        property real breatheScale: 1.0

                        SequentialAnimation {
                          running: onlineRow.isConnecting
                          loops: Animation.Infinite
                          onRunningChanged: {
                            if (!running) {
                              onlineBreatheAnim.breatheOpacity = 1.0
                              onlineBreatheAnim.breatheScale = 1.0
                            }
                          }
                          ParallelAnimation {
                            NumberAnimation { target: onlineBreatheAnim; property: "breatheOpacity"; from: 1.0; to: 0.25; duration: 650; easing.type: Easing.InOutSine }
                            NumberAnimation { target: onlineBreatheAnim; property: "breatheScale"; from: 1.0; to: 1.35; duration: 650; easing.type: Easing.InOutSine }
                          }
                          ParallelAnimation {
                            NumberAnimation { target: onlineBreatheAnim; property: "breatheOpacity"; from: 0.25; to: 1.0; duration: 650; easing.type: Easing.InOutSine }
                            NumberAnimation { target: onlineBreatheAnim; property: "breatheScale"; from: 1.35; to: 1.0; duration: 650; easing.type: Easing.InOutSine }
                          }
                        }
                      }
                    }

                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(1)

                      Text {
                        Layout.fillWidth: true
                        text: String(onlineRow.node.flag || "🏳") + "  " + onlineRow.node.name
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: onlineRow.isNodeActive || onlineRow.isConnecting
                        elide: Text.ElideRight
                      }

                      Text {
                        Layout.fillWidth: true
                        text: onlineRow.node.speedText + " · " + onlineRow.node.ping + " ms · "
                        + onlineRow.node.sessions + " users · " + onlineRow.node.uptimeText + " · "
                        + onlineRow.node.ip + ":" + onlineRow.node.port
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    PanelActionButton {
                      visible: !onlineRow.alreadySaved
                      enabled: !vpn.addingOnline && !vpn.busy
                      iconText: "󰐕"
                      tooltipText: "Add to saved nodes"
                      foreground: root.dim
                      hoverColor: Color.accent
                      fontFamily: root.fontFamily
                      Layout.alignment: Qt.AlignVCenter
                      onHovered: function(isHovered) {
                        onlineRow.actionHovered = isHovered
                      }
                      onClicked: vpn.addOnlineNode(onlineRow.node)
                    }

                    PanelActionButton {
                      visible: onlineRow.alreadySaved
                      enabled: false
                      iconText: "✓"
                      tooltipText: "Already saved in local nodes"
                      foreground: root.dim
                      hoverColor: root.dim
                      fontFamily: root.fontFamily
                      Layout.alignment: Qt.AlignVCenter
                    }
                  }
                }
              }
            }
          }

        }
      }

      Item {
        id: importFooter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.max(footerColumn.implicitHeight, Style.space(42))
        z: 10

        Column {
          id: footerColumn
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(8)

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          Row {
            id: footerButtonsRow
            visible: !root.showSetup
            width: parent.width
            spacing: Style.space(8)

            Button {
              id: selectNodeButton
              width: Math.floor((parent.width - footerButtonsRow.spacing) / 2)
              height: Style.space(32)
              text: root.showOnlineNodes ? "Saved Nodes" : "Select Node"
              iconText: root.showOnlineNodes ? "󰋜" : "󰒍"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.space(6)
              enabled: !vpn.busy && vpn.serviceAvailable
              tooltipText: root.showOnlineNodes ? "Switch to saved local nodes" : "Browse online VPN Gate nodes"
              onClicked: {
                root.showOnlineNodes = !root.showOnlineNodes
                if (root.showOnlineNodes && vpn.onlineNodes.length === 0 && !vpn.fetchingOnline) {
                  vpn.fetchOnlineNodes()
                }
              }
            }

            Button {
              id: importButton
              width: parent.width - selectNodeButton.width - footerButtonsRow.spacing
              height: Style.space(32)
              text: vpn.importing ? "Importing..." : "Import .vpn"
              iconText: vpn.importing ? "󰑐" : "󰇚"
              iconSpinning: vpn.importing
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.space(6)
              enabled: !vpn.busy && !vpn.importing && vpn.serviceAvailable
              tooltipText: "Select and import .vpn profile files (multi-selection supported)"
              onClicked: {
                root.close()
                vpn.openImportDialog()
              }
            }
          }

          Row {
            id: setupButtonsRow
            visible: root.showSetup
            width: parent.width
            spacing: Style.space(8)

            Button {
              id: setupPrimaryButton
              width: parent.width - setupRecheckButton.width - setupButtonsRow.spacing
              height: Style.space(32)
              text: {
                if (vpn.installingClient) return "Installing…"
                if (vpn.preparingSetup) return "Setting up…"
                if (vpn.setupState.client !== true) return "Install SoftEther"
                return "Set Up Automatically"
              }
              iconText: vpn.installingClient || vpn.preparingSetup ? "󰑐" : "󰒓"
              iconSpinning: vpn.installingClient || vpn.preparingSetup
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.space(6)
              enabled: !vpn.checkingSetup && !vpn.preparingSetup && !vpn.installingClient
              tooltipText: vpn.setupState.client !== true
                ? "Install the SoftEther VPN client from the AUR"
                : "Start the service, create the adapter, and add the NetworkManager profile"
              onClicked: {
                if (vpn.setupState.client !== true) vpn.installClient()
                else vpn.prepareSetup()
              }
            }

            Button {
              id: setupRecheckButton
              width: Style.space(84)
              height: Style.space(32)
              text: "Recheck"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.space(6)
              enabled: !vpn.checkingSetup && !vpn.preparingSetup && !vpn.installingClient
              tooltipText: "Check the client, service, adapter, and profile again"
              onClicked: vpn.checkSetup()
            }
          }
        }
      }

      MouseArea {
        id: countryDropdownDismiss
        visible: root.countryPopupOpen && root.showOnlineNodes && !root.showSetup
        anchors.fill: parent
        z: 90
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.countryPopupOpen = false
      }

      BorderSurface {
        id: countryDropdown
        visible: root.countryPopupOpen && root.showOnlineNodes && !root.showSetup
        z: 100
        anchors.top: headerColumn.bottom
        anchors.topMargin: Style.space(2)
        anchors.left: parent.left
        width: Math.min(parent.width, Style.space(260))
        height: Math.min(dropdownColumn.implicitHeight + Style.space(16), Style.space(280))
        color: root.bar ? root.bar.background : Color.background
        borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
        radius: Style.cornerRadius
        padding: Style.space(6)
        clip: true

        Flickable {
          id: dropdownFlickable
          anchors.fill: parent
          contentWidth: width
          contentHeight: dropdownColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: dropdownColumn
            width: dropdownFlickable.width
            spacing: Style.space(2)

            CursorSurface {
              width: parent.width
              height: Style.space(30)
              radius: Style.cornerRadius / 2
              current: root.selectedOnlineCountry === ""
              foreground: root.foreground

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(8)

                Text {
                  text: "🌐"
                  font.pixelSize: Style.font.body
                  Layout.alignment: Qt.AlignVCenter
                }

                Text {
                  text: "All Countries"
                  color: root.selectedOnlineCountry === "" ? Color.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: root.selectedOnlineCountry === ""
                  Layout.fillWidth: true
                  Layout.alignment: Qt.AlignVCenter
                  elide: Text.ElideRight
                }

                Text {
                  text: "(" + vpn.onlineNodes.length + ")"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.alignment: Qt.AlignVCenter
                }

                Text {
                  visible: root.selectedOnlineCountry === ""
                  text: "✓"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  Layout.alignment: Qt.AlignVCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.selectedOnlineCountry = ""
                  root.selectedOnlineCountryName = "All"
                  root.selectedOnlineCountryFlag = ""
                  root.countryPopupOpen = false
                }
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }

            Repeater {
              model: root.countryList

              CursorSurface {
                required property var modelData
                required property int index
                readonly property bool isSelected: root.selectedOnlineCountry === modelData.code

                width: parent.width
                height: Style.space(30)
                radius: Style.cornerRadius / 2
                current: isSelected
                foreground: root.foreground

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(8)

                  Text {
                    text: modelData.flag
                    font.pixelSize: Style.font.body
                    Layout.alignment: Qt.AlignVCenter
                  }

                  Text {
                    text: modelData.name
                    color: isSelected ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: isSelected
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    elide: Text.ElideRight
                  }

                  Text {
                    text: "(" + modelData.count + ")"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    Layout.alignment: Qt.AlignVCenter
                  }

                  Text {
                    visible: isSelected
                    text: "✓"
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    Layout.alignment: Qt.AlignVCenter
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.selectedOnlineCountry = modelData.code
                    root.selectedOnlineCountryName = modelData.name
                    root.selectedOnlineCountryFlag = modelData.flag
                    root.countryPopupOpen = false
                  }
                }
              }
            }
          }
        }
      }

    Local.ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 120
        opened: false
        message: root.confirmMessage
        confirmText: root.confirmButtonText
        cancelText: "Cancel"
        background: root.bar ? root.bar.background : Color.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        cornerRadius: Style.cornerRadius
        onCanceled: function() {
          opened = false
          root.pendingAction = ""
          root.pendingAccount = null
        }
        onConfirmed: function() {
          opened = false
          if (root.pendingAction === "disconnect") {
            vpn.disconnectVpn()
          } else if (root.pendingAction === "connect") {
            vpn.connectVpn()
          } else if (root.pendingAction === "connect_account") {
            if (root.pendingAccount) {
              vpn.connectToAccount(root.pendingAccount.name)
            }
          } else if (root.pendingAction === "connect_online") {
            if (root.pendingAccount) {
              vpn.connectToOnlineNode(root.pendingAccount)
            }
          } else if (root.pendingAction === "delete_account") {
            if (root.pendingAccount && root.pendingAccount.name) {
              var nameToDelete = root.pendingAccount.name
              root.removeAccountFromOrder(nameToDelete)
              if (root.settings && root.settings.accountName === nameToDelete) {
                root.persistSelection("")
              }
              vpn.deleteAccount(nameToDelete)
            }
          }
          root.pendingAction = ""
          root.pendingAccount = null
        }
      }

      Local.RenameDialog {
        id: renameDialog
        anchors.fill: parent
        z: 125
        opened: false
        background: root.bar ? root.bar.background : Color.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        cornerRadius: Style.cornerRadius
        accent: Color.accent
        onCanceled: function() {
          Qt.callLater(function() {
            keyCatcher.forceActiveFocus()
          })
        }
        onConfirmed: function(newName) {
          vpn.renameAccount(root.renameAccountTarget, newName)
          Qt.callLater(function() {
            keyCatcher.forceActiveFocus()
          })
        }
      }
    }
  }
}
