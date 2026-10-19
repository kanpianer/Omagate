var MAX_COMMAND_CHARS = 65536
var MAX_NETWORK_CHARS = 32768
var MAX_LINES = 1024
var MAX_ACCOUNTS = 128
var MAX_ROW_CHARS = 1024
var MAX_FIELD_CHARS = 256
var MAX_JSON_ITEMS = 128
var MAX_ACCOUNT_NAME_LENGTH = 128
var MAX_PROFILE_NAME_LENGTH = 128

var RE_SPACE_ENCODED = /\$20/g
var RE_VALID_SETTING = /^[A-Za-z0-9#][A-Za-z0-9._@()+,#%=-]*( [A-Za-z0-9._@()+,#%=-]+)*$/
var RE_VALID_ADAPTER = /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/
var RE_SPACES = /\s+/g
var RE_STATUS_OFFLINE = /disconnect|offline|not connected|disabled|stopped/
var RE_STATUS_CONNECTING = /connecting|retry|negotiat/
var RE_STATUS_CONNECTED = /connected|online|established/
var RE_LINES = /\r?\n/
var RE_KEY_SETTING = /^(vpn connection setting name|account name|connection setting name)$/
var RE_VALID_IP_CHARS = /^[0-9A-Fa-f:.]+$/

function bounded(value, maximum) {
  var text = String(value || "")
  return text.length <= maximum ? text : null
}

function decoded(value) {
  var text = bounded(value, MAX_FIELD_CHARS)
  return text === null ? "" : text.replace(RE_SPACE_ENCODED, " ").trim()
}

function validNamedSetting(value, maximum, allowEmpty) {
  var text = String(value || "")
  if (allowEmpty && text === "") return true
  if (text.length < 1 || text.length > maximum) return false
  return RE_VALID_SETTING.test(text)
}

function validAccountName(value, allowEmpty) {
  return validNamedSetting(value, MAX_ACCOUNT_NAME_LENGTH, allowEmpty === true)
}

function validProfileName(value) {
  return validNamedSetting(value, MAX_PROFILE_NAME_LENGTH, false)
}

function validAdapterName(value) {
  var text = String(value || "")
  return text.length >= 1 && text.length <= 15
    && RE_VALID_ADAPTER.test(text)
}

function settingsError(accountName, profileName, adapterName) {
  if (!validAccountName(accountName, true)) return "Invalid preferred SoftEther account setting"
  if (!validProfileName(profileName)) return "Invalid NetworkManager profile setting"
  if (!validAdapterName(adapterName)) return "Invalid virtual adapter setting"
  return ""
}

function elideError(value) {
  var text = String(value || "")
  if (text.length > 4096) text = text.substring(0, 4096)
  text = text.replace(RE_SPACES, " ").trim()
  return text.length > 180 ? text.substring(0, 177) + "…" : text
}

function tableRow(line) {
  var text = bounded(line, MAX_ROW_CHARS)
  if (text === null) return null
  var separator = text.indexOf("|")
  if (separator < 0) return null
  var key = text.substring(0, separator).trim()
  var value = decoded(text.substring(separator + 1))
  if (key.length === 0 || key.length > 128 || value.length > MAX_FIELD_CHARS) return null
  return {
    key: key,
    value: value
  }
}

function statusKind(value) {
  var status = String(value || "").trim().toLowerCase()
  if (RE_STATUS_OFFLINE.test(status)) return "offline"
  if (RE_STATUS_CONNECTING.test(status)) return "connecting"
  if (RE_STATUS_CONNECTED.test(status)) return "connected"
  return status === "" ? "offline" : "unknown"
}

function presentationState(options) {
  var state = options || {}
  if (!state.installed || !state.serviceAvailable) return "error"
  if (String(state.lastError || "") !== "") return "error"

  // A requested disconnect is optimistically off. NetworkManager removes the
  // address and route before AccountList reports Offline, and treating that
  // expected gap as an unusable connection produces a false warning badge.
  if (state.desiredState === 0 || state.actionKind === "disconnect") return "off"
  if (state.actionKind === "connect" || state.desiredState === 1 || state.connecting)
    return "connecting"
  if (state.connected && !state.usable) return "warning"
  if (state.connected) return "on"
  return "off"
}

function shouldPulse(actionKind) {
  return String(actionKind || "") === "connect"
}

// The connection switch shows what the tunnel is doing, not what the client
// claims. SoftEther can keep listing a session after the network or the server
// dropped it, and a session without an address or a default route is not a
// working VPN, so it must not hold the switch on. A connect the user asked for
// stays on until that request settles; a requested disconnect stays off.
function switchOn(options) {
  var state = options || {}
  if (state.desiredState === 0) return false
  if (state.desiredState === 1) return true
  return Boolean(state.connected || state.connecting || state.usable)
}

function parseAccountList(raw) {
  var input = bounded(raw, MAX_COMMAND_CHARS)
  if (input === null) return []
  var lines = input.split(RE_LINES)
  if (lines.length > MAX_LINES) return []
  var accounts = []
  var current = null
  var seen = Object.create(null)
  var seenIp = Object.create(null)

  function finish() {
    if (!current || !validAccountName(current.name, false)) return
    if (accounts.length >= MAX_ACCOUNTS || seen[current.name]) return
    current.statusKind = statusKind(current.status)
    var host = (current.server || "").split(":")[0].trim()
    var isActive = current.statusKind === "connected" || current.statusKind === "connecting"
    if (current.name !== "VPNGate_Direct" && !isActive && host && seenIp[host]) return
    accounts.push(current)
    seen[current.name] = true
    if (current.name !== "VPNGate_Direct" && host) seenIp[host] = true
  }

  for (var i = 0; i < lines.length; i++) {
    var row = tableRow(lines[i])
    if (!row) continue
    var key = row.key.toLowerCase()

    if (RE_KEY_SETTING.test(key)) {
      finish()
      current = { name: row.value, status: "Offline", server: "", hub: "", adapter: "" }
      continue
    }
    if (!current) continue
    if (key === "status" || key === "connection status") current.status = row.value
    else if (key === "vpn server hostname" || key === "server hostname") current.server = row.value
    else if (key === "virtual hub" || key === "virtual hub name") current.hub = row.value
    else if (key === "virtual network adapter name") current.adapter = row.value
  }
  finish()
  return accounts
}

function parseAddress(raw) {
  try {
    var input = bounded(raw, MAX_NETWORK_CHARS)
    if (input === null) return ""
    var devices = JSON.parse(input || "[]")
    if (!Array.isArray(devices) || devices.length > MAX_JSON_ITEMS) return ""
    for (var i = 0; i < devices.length; i++) {
      var addresses = devices[i].addr_info || []
      if (!Array.isArray(addresses) || addresses.length > MAX_JSON_ITEMS) return ""
      for (var j = 0; j < addresses.length; j++) {
        var address = addresses[j] || {}
        var local = String(address.local || "")
        if (address.scope === "global" && (address.family === "inet" || address.family === "inet6")
            && local.length >= 2 && local.length <= 64 && RE_VALID_IP_CHARS.test(local))
          return local
      }
    }
  } catch (e) {
  }
  return ""
}

function hasDefaultRoute(raw, adapterName) {
  try {
    var input = bounded(raw, MAX_NETWORK_CHARS)
    if (input === null || !validAdapterName(adapterName)) return false
    var routes = JSON.parse(input || "[]")
    if (!Array.isArray(routes) || routes.length > MAX_JSON_ITEMS) return false
    var adapter = String(adapterName || "")
    for (var i = 0; i < routes.length; i++) {
      var route = routes[i] || {}
      var destination = String(route.dst || "default")
      var device = String(route.dev || "")
      if (destination.length <= 64 && device.length <= 15
          && destination === "default" && device === adapter)
        return true
    }
  } catch (e) {
  }
  return false
}

function asArray(val) {
  if (!val) return []
  if (Array.isArray(val)) return val.slice()
  if (val instanceof Array) {
    var out = []
    for (var i = 0; i < val.length; i++) out.push(val[i])
    return out
  }
  if (typeof val === "object" && typeof val.length === "number") {
    var out2 = []
    for (var j = 0; j < val.length; j++) out2.push(val[j])
    return out2
  }
  return []
}

function sortAccounts(accounts, order) {
  var raw = asArray(accounts)
  var ord = asArray(order)
  if (raw.length <= 1 || ord.length === 0) return raw

  var map = Object.create(null)
  for (var i = 0; i < raw.length; i++) {
    var acc = raw[i]
    if (acc && acc.name) {
      map[acc.name] = acc
    }
  }

  var result = []
  for (var j = 0; j < ord.length; j++) {
    var name = String(ord[j] || "")
    var item = map[name]
    if (item) {
      result.push(item)
      map[name] = null
    }
  }
  for (var k = 0; k < raw.length; k++) {
    var acc2 = raw[k]
    if (acc2 && acc2.name && map[acc2.name]) {
      result.push(acc2)
    }
  }
  return result
}

function getCountryList(nodes) {
  var raw = asArray(nodes)
  var map = Object.create(null)
  var list = []
  for (var i = 0; i < raw.length; i++) {
    var n = raw[i]
    if (!n || !n.countryCode) continue
    var code = String(n.countryCode).toUpperCase()
    if (!map[code]) {
      map[code] = {
        code: code,
        name: n.country || code,
        flag: n.flag || "🏳",
        count: 0
      }
      list.push(map[code])
    }
    map[code].count++
  }
  list.sort(function(a, b) {
    return b.count - a.count || a.name.localeCompare(b.name)
  })
  return list
}

function filterAndSortOnlineNodes(nodes, countryFilter, sortField, sortAsc, activeServerIp) {
  var raw = asArray(nodes)
  var filtered = []
  var filterUpper = countryFilter ? String(countryFilter).toUpperCase() : ""

  for (var i = 0; i < raw.length; i++) {
    var n = raw[i]
    if (!n) continue
    if (filterUpper !== "") {
      var cCode = String(n.countryCode || "").toUpperCase()
      if (cCode !== filterUpper && String(n.country || "") !== countryFilter) {
        continue
      }
    }
    filtered.push(n)
  }

  var field = sortField || "speed"

  filtered.sort(function(a, b) {
    var valA = a[field] !== undefined ? a[field] : 0
    var valB = b[field] !== undefined ? b[field] : 0

    if (valA !== valB) {
      if (sortAsc) return valA > valB ? 1 : -1
      else return valA < valB ? 1 : -1
    }

    return (b.speed || 0) - (a.speed || 0)
  })

  return filtered
}


if (typeof module !== "undefined") {
  module.exports = {
    decoded: decoded,
    bounded: bounded,
    validAccountName: validAccountName,
    validProfileName: validProfileName,
    validAdapterName: validAdapterName,
    settingsError: settingsError,
    elideError: elideError,
    tableRow: tableRow,
    statusKind: statusKind,
    presentationState: presentationState,
    shouldPulse: shouldPulse,
    switchOn: switchOn,
    parseAccountList: parseAccountList,
    parseAddress: parseAddress,
    hasDefaultRoute: hasDefaultRoute,
    asArray: asArray,
    sortAccounts: sortAccounts,
    getCountryList: getCountryList,
    filterAndSortOnlineNodes: filterAndSortOnlineNodes
  }
}
