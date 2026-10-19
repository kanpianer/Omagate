const assert = require("node:assert/strict")
const model = require("../Model.js")

const ready = {
  installed: true,
  serviceAvailable: true,
  lastError: "",
  actionKind: "",
  desiredState: -1,
  connecting: false,
  connected: false,
  usable: false
}

function state(overrides) {
  return model.presentationState({ ...ready, ...overrides })
}

assert.equal(state({}), "off")
assert.equal(state({ connected: true, usable: true }), "on")
assert.equal(state({ connecting: true }), "connecting")
assert.equal(state({ actionKind: "connect", desiredState: 1 }), "connecting")

// Startup status polling must not manufacture a connecting state.
assert.equal(state({ actionKind: "", desiredState: -1 }), "off")
assert.equal(model.shouldPulse(""), false)
assert.equal(model.shouldPulse("disconnect"), false)
assert.equal(model.shouldPulse("connect"), true)

// An externally reported connecting account can still be described accurately
// without playing an animation that implies the widget initiated the action.
assert.equal(state({ connecting: true }), "connecting")
assert.equal(model.shouldPulse(""), false)

// During a normal disconnect, the route can disappear before AccountList
// changes to Offline. That expected intermediate state must not turn red.
assert.equal(state({
  actionKind: "disconnect",
  desiredState: 0,
  connected: true,
  usable: false
}), "off")

assert.equal(state({ connected: true, usable: false }), "warning")
assert.equal(state({ lastError: "command failed", desiredState: 0 }), "error")
assert.equal(state({ installed: false }), "error")

// The switch follows the tunnel, not the client's session list: a session that
// survived the link dropping (usable false) must read as off, while a connect
// the user asked for stays on until that request settles.
assert.equal(model.switchOn({ desiredState: -1, usable: true }), true)
assert.equal(model.switchOn({ desiredState: -1, usable: false }), false)
assert.equal(model.switchOn({ desiredState: -1, connected: true, usable: false }), true)
assert.equal(model.switchOn({ desiredState: -1, connecting: true, usable: false }), true)
assert.equal(model.switchOn({ desiredState: 1, usable: false }), true)
assert.equal(model.switchOn({ desiredState: 1, usable: true }), true)
assert.equal(model.switchOn({ desiredState: 0, usable: true }), false)
assert.equal(model.switchOn({ desiredState: 0, usable: false }), false)
assert.equal(model.switchOn({ desiredState: 0, connected: true }), false)
assert.equal(model.switchOn(undefined), false)

assert.equal(model.validAccountName("Test VPN Germany", false), true)
assert.equal(model.validAccountName("#AU TPG 4%", false), true)
assert.equal(model.validAccountName("#JP Sony 4% wz", false), true)
assert.equal(model.validAccountName("", true), true)
assert.equal(model.validAccountName("<b>unsafe</b>", false), false)
assert.equal(model.validAccountName("line\nbreak", false), false)
assert.equal(model.validAccountName("A".repeat(129), false), false)
assert.equal(model.validProfileName("SoftEther VPN Network"), true)
assert.equal(model.validProfileName("profile|route-state", false), false)
assert.equal(model.validAdapterName("vpn_vpn"), true)
assert.equal(model.validAdapterName("adapter/name"), false)
assert.equal(model.validAdapterName("a".repeat(16)), false)
assert.equal(model.settingsError("", "SoftEther VPN Network", "vpn_vpn"), "")
assert.match(model.settingsError("", "bad\nprofile", "vpn_vpn"), /NetworkManager/)

const accountRow = [
  "VPN Connection Setting Name | Test VPN Germany",
  "Status | Connected",
  "VPN Server Hostname | vpn.example.com"
].join("\n")
assert.equal(model.parseAccountList(accountRow).length, 1)
assert.equal(model.parseAccountList("A".repeat(65537)).length, 0)
assert.equal(model.parseAccountList("x\n".repeat(1025)).length, 0)
assert.equal(model.parseAccountList(
  "VPN Connection Setting Name | <b>unsafe</b>\nStatus | Connected").length, 0)

const manyAccounts = Array.from({ length: 140 }, (_, index) =>
  `VPN Connection Setting Name | VPN ${index}\nStatus | Offline`).join("\n")
assert.equal(model.parseAccountList(manyAccounts).length, 128)

// IP deduplication test: if identical IPs exist, only keep the earliest node
const dupIpAccounts = [
  "VPN Connection Setting Name | Node First",
  "Status | Offline",
  "VPN Server Hostname | 192.168.1.100:443",
  "VPN Connection Setting Name | Node Second",
  "Status | Offline",
  "VPN Server Hostname | 192.168.1.100:1194",
  "VPN Connection Setting Name | Node Third",
  "Status | Offline",
  "VPN Server Hostname | 10.0.0.1:443"
].join("\n")
const parsedDups = model.parseAccountList(dupIpAccounts)
assert.equal(parsedDups.length, 2)
assert.equal(parsedDups[0].name, "Node First")
assert.equal(parsedDups[1].name, "Node Third")

// Test that VPNGate_Direct is never dropped even if it shares an IP with a saved account
const dupWithDirect = [
  "VPN Connection Setting Name | #US 135.180.93.53",
  "Status | Offline",
  "VPN Server Hostname | 135.180.93.53:1919",
  "VPN Connection Setting Name | VPNGate_Direct",
  "Status | Connected",
  "VPN Server Hostname | 135.180.93.53:1919"
].join("\n")
const parsedDirect = model.parseAccountList(dupWithDirect)
assert.equal(parsedDirect.length, 2)
assert.equal(parsedDirect[0].name, "#US 135.180.93.53")
assert.equal(parsedDirect[1].name, "VPNGate_Direct")
assert.equal(parsedDirect[1].statusKind, "connected")

// Test that an active (connected/connecting) account is never dropped by duplicate IP
const dupWithActive = [
  "VPN Connection Setting Name | Saved Node Old",
  "Status | Offline",
  "VPN Server Hostname | 23.93.5.4:1000",
  "VPN Connection Setting Name | Saved Node Active",
  "Status | Connected",
  "VPN Server Hostname | 23.93.5.4:1782"
].join("\n")
const parsedActive = model.parseAccountList(dupWithActive)
assert.equal(parsedActive.length, 2)

assert.equal(model.parseAddress("x".repeat(32769)), "")
assert.equal(model.parseAddress(JSON.stringify(Array.from({ length: 129 }, () => ({})))), "")
assert.equal(model.hasDefaultRoute("x".repeat(32769), "vpn_vpn"), false)
assert.equal(model.hasDefaultRoute(JSON.stringify(Array.from({ length: 129 }, () => ({}))), "vpn_vpn"), false)
assert.ok(model.elideError("x".repeat(5000)).length <= 180)
assert.ok(model.elideError("x".repeat(5000)).endsWith("…"))

const acc1 = { name: "Node 1" }
const acc2 = { name: "Node 2" }
const acc3 = { name: "Node 3" }
assert.deepEqual(model.sortAccounts([acc1, acc2, acc3], ["Node 3", "Node 1", "Node 2"]), [acc3, acc1, acc2])
assert.deepEqual(model.sortAccounts([acc1, acc2, acc3], ["Node 2"]), [acc2, acc1, acc3])
assert.deepEqual(model.sortAccounts([acc1, acc2, acc3], []), [acc1, acc2, acc3])
assert.deepEqual(model.sortAccounts([acc1], ["Node 1"]), [acc1])

// Test array-like objects (e.g. QML QVariantList cross-context array wrappers)
const arrayLikeOrder = { 0: "Node 2", 1: "Node 3", length: 2 }
assert.deepEqual(model.asArray(arrayLikeOrder), ["Node 2", "Node 3"])
assert.deepEqual(model.asArray(null), [])
assert.deepEqual(model.asArray(undefined), [])
assert.deepEqual(model.asArray(["a", "b"]), ["a", "b"])
assert.deepEqual(model.sortAccounts([acc1, acc2, acc3], arrayLikeOrder), [acc2, acc3, acc1])

// Test getCountryList
const sampleOnlineNodes = [
  { name: "#JP 1.1.1.1", ip: "1.1.1.1", countryCode: "JP", country: "Japan", flag: "🇯🇵", speed: 500, sessions: 10, uptime: 1000, ping: 15 },
  { name: "#US 2.2.2.2", ip: "2.2.2.2", countryCode: "US", country: "United States", flag: "🇺🇸", speed: 800, sessions: 5, uptime: 5000, ping: 50 },
  { name: "#JP 3.3.3.3", ip: "3.3.3.3", countryCode: "JP", country: "Japan", flag: "🇯🇵", speed: 200, sessions: 20, uptime: 2000, ping: 8 }
]
const countries = model.getCountryList(sampleOnlineNodes)
assert.equal(countries.length, 2)
assert.equal(countries[0].code, "JP")
assert.equal(countries[0].count, 2)
assert.equal(countries[1].code, "US")
assert.equal(countries[1].count, 1)

// Test filterAndSortOnlineNodes: Country filter
const jpOnly = model.filterAndSortOnlineNodes(sampleOnlineNodes, "JP", "speed", false, "")
assert.equal(jpOnly.length, 2)
assert.equal(jpOnly[0].ip, "1.1.1.1") // 500 > 200
assert.equal(jpOnly[1].ip, "3.3.3.3")

// Test filterAndSortOnlineNodes: Active/connecting node is not pinned to top, keeps original position
const activeNotPinned = model.filterAndSortOnlineNodes(sampleOnlineNodes, "", "speed", false, "3.3.3.3")
assert.equal(activeNotPinned.length, 3)
assert.equal(activeNotPinned[0].ip, "2.2.2.2") // speed 800
assert.equal(activeNotPinned[1].ip, "1.1.1.1") // speed 500
assert.equal(activeNotPinned[2].ip, "3.3.3.3") // speed 200 (retains sorted position)

// Test filterAndSortOnlineNodes: Sessions sort (descending)
const bySessions = model.filterAndSortOnlineNodes(sampleOnlineNodes, "", "sessions", false, "")
assert.equal(bySessions[0].sessions, 20)
assert.equal(bySessions[1].sessions, 10)
assert.equal(bySessions[2].sessions, 5)

// Test filterAndSortOnlineNodes: Uptime sort (ascending)
const byUptimeAsc = model.filterAndSortOnlineNodes(sampleOnlineNodes, "", "uptime", true, "")
assert.equal(byUptimeAsc[0].uptime, 1000)
assert.equal(byUptimeAsc[1].uptime, 2000)
assert.equal(byUptimeAsc[2].uptime, 5000)

// Test filterAndSortOnlineNodes: Ping sort (ascending: lowest ping first)
const byPingAsc = model.filterAndSortOnlineNodes(sampleOnlineNodes, "", "ping", true, "")
assert.equal(byPingAsc[0].ping, 8)
assert.equal(byPingAsc[1].ping, 15)
assert.equal(byPingAsc[2].ping, 50)

// Test filterAndSortOnlineNodes: Ping sort (descending: highest ping first)
const byPingDesc = model.filterAndSortOnlineNodes(sampleOnlineNodes, "", "ping", false, "")
assert.equal(byPingDesc[0].ping, 50)
assert.equal(byPingDesc[1].ping, 15)
assert.equal(byPingDesc[2].ping, 8)

console.log("model state tests passed")

