------------------------------------------------------------
-- SGC CONTROL SYSTEM
-- Minecraft 1.12.2
-- SGCraft 2.0.5 + OpenComputers + OpenSecurity
------------------------------------------------------------

local component = require("component")
local computer = require("computer")
local event = require("event")
local term = require("term")
local filesystem = require("filesystem")

------------------------------------------------------------
-- CONFIGURATION
------------------------------------------------------------

local LOG_DIRECTORY = "/home/logs"
local LOG_FILE = LOG_DIRECTORY .. "/gate.log"
local MISSION_LOG_FILE = LOG_DIRECTORY .. "/missions.log"

-- Durée maximale autorisée pour une composition
local DIAL_TIMEOUT = 60

-- Temps pendant lequel l'alarme sonne après le début
-- de la composition. Mettre 0 pour la laisser sonner
-- jusqu'à la connexion ou l'échec.
local ALARM_DURATION = 0

-- Sécurité des connexions entrantes.
-- L'iris se ferme dès que SGCraft signale un appel entrant.
local AUTO_CLOSE_IRIS_ON_INCOMING = true

-- L'alarme entrante reste active jusqu'à l'affichage de l'alerte.
local INCOMING_ALARM = true

-- Carnet d'adresses.
-- Remplace les exemples par les vraies adresses de tes portes.
-- Les noms sont saisis sans distinction entre majuscules/minuscules.
local ADDRESS_BOOK = {
  Terre = "ZFVS-MY6-DJ",
  Abydos = "BFVG-A4I-W7",
  Chulak = "FFFK-ZPU-77",
  P4X354 = "645Y-ITQ-KC"
}

-- Informations tactiques et diplomatiques.
local DESTINATION_DATA = {
  terre = {
    galaxy = "Voie Lactee",
    status = "BASE PRINCIPALE",
    threat = "SECURISE",
    notes = "Stargate Command."
  },
  abydos = {
    galaxy = "Voie Lactee",
    status = "ALLIE",
    threat = "FAIBLE",
    notes = "Monde desertique. Population amicale."
  },
  chulak = {
    galaxy = "Voie Lactee",
    status = "HOSTILE",
    threat = "ELEVE",
    notes = "Ancien monde Goa'uld. Reconnaissance armee conseillee."
  },
  p4x354 = {
    galaxy = "Voie Lactee",
    status = "NON DETERMINE",
    threat = "INCONNU",
    notes = "Donnees insuffisantes."
  }
}

local SG_TEAMS = {
  "SG-1",
  "SG-2",
  "SG-3",
  "SG-4"
}

local MISSION_TYPES = {
  "Reconnaissance",
  "Diplomatie",
  "Exploration",
  "Secours",
  "Ravitaillement",
  "Operation tactique"
}


------------------------------------------------------------
-- VARIABLES GLOBALES
------------------------------------------------------------

local gate = nil
local gateAddress = nil

local alarm = nil
local alarmAddress = nil

local alarmActive = false

-- Dernière connexion entrante signalée par SGCraft.
local pendingIncoming = nil
local incomingListenerInstalled = false

------------------------------------------------------------
-- OUTILS
------------------------------------------------------------

local function pause(seconds)
  os.sleep(seconds or 2)
end

local function waitForEnter()
  print()
  io.write("Appuie sur Entree pour continuer...")
  io.read()
end

local function clear()
  term.clear()
  term.setCursor(1, 1)
end

local function safeToString(value)
  if value == nil then
    return "INCONNU"
  end

  return tostring(value)
end

------------------------------------------------------------
-- JOURNAL
------------------------------------------------------------

local function initializeLog()
  if not filesystem.exists(LOG_DIRECTORY) then
    filesystem.makeDirectory(LOG_DIRECTORY)
  end
end

local function log(message)
  initializeLog()

  local file, reason = io.open(LOG_FILE, "a")

  if not file then
    return false, reason
  end

  local timestamp

  if os.date then
    timestamp = os.date("%Y-%m-%d %H:%M:%S")
  else
    timestamp = "UPTIME " .. math.floor(computer.uptime())
  end

  file:write("[" .. timestamp .. "] " .. tostring(message) .. "\n")
  file:close()

  return true
end

local function missionLog(message)
  initializeLog()

  local file, reason = io.open(MISSION_LOG_FILE, "a")

  if not file then
    log("ERREUR JOURNAL MISSIONS : " ..
      safeToString(reason))
    return false, reason
  end

  local timestamp

  if os.date then
    timestamp = os.date("%Y-%m-%d %H:%M:%S")
  else
    timestamp = "UPTIME " ..
      math.floor(computer.uptime())
  end

  file:write(
    "[" .. timestamp .. "] " ..
    tostring(message) .. "\n"
  )
  file:close()

  return true
end

------------------------------------------------------------
-- AFFICHAGE
------------------------------------------------------------

local function header()
  clear()

  print("================================")
  print("          SGC CONTROL")
  print("   STARGATE COMMAND SYSTEM")
  print("================================")
  print()
end

local function separator()
  print("--------------------------------")
end

------------------------------------------------------------
-- DÉTECTION DES COMPOSANTS
------------------------------------------------------------

local function findGate()
  -- Noms de composants connus ou possibles
  local acceptedTypes = {
    stargate = true,
    stargate_base = true,
    sg_controller = true
  }

  for address, componentType in component.list() do
    if acceptedTypes[componentType] then
      gate = component.proxy(address)
      gateAddress = address
      return true
    end

    -- Détection de secours pour un type contenant "stargate"
    if tostring(componentType):lower():find("stargate", 1, true) then
      gate = component.proxy(address)
      gateAddress = address
      return true
    end
  end

  return false
end

local function findAlarm()
  local acceptedTypes = {
    os_alarm = true,
    opensecurity_alarm = true,
    alarm = true
  }

  for address, componentType in component.list() do
    if acceptedTypes[componentType] then
      alarm = component.proxy(address)
      alarmAddress = address
      return true
    end
  end

  return false
end

------------------------------------------------------------
-- CONTRÔLE DE L'ALARME
------------------------------------------------------------

local function siren(enabled)
  if not alarm then
    alarmActive = false
    return false, "Aucune alarme detectee"
  end

  local ok
  local result

  if enabled then
    ok, result = pcall(alarm.activate)
  else
    ok, result = pcall(alarm.deactivate)
  end

  if ok then
    alarmActive = enabled
    return true
  end

  log("ERREUR ALARME : " .. tostring(result))
  return false, result
end

local function emergencyAlarmStop()
  if alarm then
    -- Plusieurs essais pour maximiser les chances d'arrêt
    pcall(alarm.deactivate)
    pcall(alarm.stop)
    pcall(alarm.setActive, false)
  end

  alarmActive = false
end

------------------------------------------------------------
-- INFORMATIONS DE LA PORTE
------------------------------------------------------------

local function getGateState()
  if not gate then
    return "Offline", 0, "Unknown"
  end

  if not gate.stargateState then
    return "API_INCOMPATIBLE", 0, "Unknown"
  end

  local ok, state, chevrons, direction =
    pcall(gate.stargateState)

  if not ok then
    return "ERROR", 0, tostring(state)
  end

  return state or "Unknown",
         chevrons or 0,
         direction or "Unknown"
end

local function getEnergy()
  if not gate or not gate.energyAvailable then
    return nil, "Methode energyAvailable indisponible"
  end

  local ok, value = pcall(gate.energyAvailable)

  if not ok then
    return nil, value
  end

  return tonumber(value), nil
end

local function getLocalAddress()
  if not gate or not gate.localAddress then
    return nil
  end

  local ok, address = pcall(gate.localAddress)

  if not ok then
    return nil
  end

  return address
end

local function getRemoteAddress()
  if not gate or not gate.remoteAddress then
    return nil
  end

  local ok, address = pcall(gate.remoteAddress)

  if not ok or not address or address == "" then
    return nil
  end

  return normalizeAddress and normalizeAddress(address)
      or tostring(address)
end

local function getIrisState()
  if not gate or not gate.irisState then
    return "INDISPONIBLE"
  end

  local ok, state, reason = pcall(gate.irisState)

  if not ok then
    return "ERREUR"
  end

  if state == nil then
    return "ERREUR: " .. safeToString(reason)
  end

  return state
end

local function setIris(open)
  header()

  if not gate then
    print("ERREUR : PORTE NON DETECTEE")
    waitForEnter()
    return false
  end

  local method = open and gate.openIris or gate.closeIris
  local action = open and "OUVERTURE" or "FERMETURE"

  if not method then
    print("ERREUR API")
    print("La commande d'iris est indisponible.")
    waitForEnter()
    return false
  end

  print(action .. " DE L'IRIS")
  separator()
  print("Etat initial : " .. safeToString(getIrisState()))
  print()

  local ok, result, reason = pcall(method)

  if not ok then
    print("ECHEC : " .. safeToString(result))
    log("Erreur iris : " .. safeToString(result))
    waitForEnter()
    return false
  end

  if result == nil then
    print("ECHEC : " .. safeToString(reason))
    log("Erreur iris : " .. safeToString(reason))
    waitForEnter()
    return false
  end

  local timeout = computer.uptime() + 10
  local wanted = open and "Open" or "Closed"

  while computer.uptime() < timeout do
    local state = getIrisState()

    if state == wanted then
      print("Iris " .. (open and "ouvert." or "ferme."))
      log("Iris " .. (open and "ouvert" or "ferme"))
      waitForEnter()
      return true
    end

    os.sleep(0.25)
  end

  print("Commande envoyee.")
  print("Etat actuel : " .. safeToString(getIrisState()))
  waitForEnter()
  return true
end

local function irisMenu()
  while true do
    header()
    print("CONTROLE DE L'IRIS")
    separator()
    print("Etat : " .. safeToString(getIrisState()))
    print()
    print("1 - Ouvrir l'iris")
    print("2 - Fermer l'iris")
    print("3 - Retour")
    print()
    io.write("Commande IRIS > ")

    local choice = io.read()

    if pendingIncoming then
      incomingConnectionScreen()
    elseif choice == "1" then
      setIris(true)
    elseif choice == "2" then
      setIris(false)
    elseif choice == "3" then
      return
    else
      print("Commande inconnue.")
      pause(1)
    end
  end
end

local function getDialCost(address)
  if not gate or not gate.energyToDial then
    return nil, "Methode energyToDial indisponible"
  end

  local ok, value = pcall(gate.energyToDial, address)

  if not ok then
    return nil, value
  end

  return tonumber(value), nil
end

------------------------------------------------------------
-- NORMALISATION DES ADRESSES
------------------------------------------------------------

local function normalizeAddress(address)
  address = tostring(address or "")

  -- Retire espaces, tabulations et retours à la ligne
  address = address:gsub("%s+", "")

  -- Retire les tirets pour accepter ABC-DEF-G
  address = address:gsub("%-", "")

  address = address:upper()

  return address
end

local function normalizeName(name)
  name = tostring(name or ""):lower()
  name = name:gsub("^%s+", "")
  name = name:gsub("%s+$", "")
  return name
end

local function resolveDestination(input)
  local requestedName = normalizeName(input)

  for savedName, savedAddress in pairs(ADDRESS_BOOK) do
    if normalizeName(savedName) == requestedName then
      return normalizeAddress(savedAddress),
             normalizeName(savedName)
    end
  end

  return normalizeAddress(input), nil
end

local function findDestinationByAddress(rawAddress)
  local searched = normalizeAddress(rawAddress)

  if searched == "" then
    return nil
  end

  for savedName, savedAddress in pairs(ADDRESS_BOOK) do
    if normalizeAddress(savedAddress) == searched then
      return tostring(savedName)
    end
  end

  return nil
end

local function closeIrisImmediately()
  if not gate or not gate.closeIris then
    return false, "Commande closeIris indisponible"
  end

  local ok, result, reason = pcall(gate.closeIris)

  if not ok then
    return false, result
  end

  if result == nil then
    return false, reason
  end

  return true
end

local function incomingEventHandler(_, source, remoteAddress)
  if source ~= gateAddress then
    return
  end

  local address = normalizeAddress(remoteAddress or "")
  local knownName = findDestinationByAddress(address)

  pendingIncoming = {
    address = address,
    name = knownName,
    detectedAt = computer.uptime(),
    irisCommandSent = false,
    irisError = nil
  }

  if AUTO_CLOSE_IRIS_ON_INCOMING then
    local ok, reason = closeIrisImmediately()
    pendingIncoming.irisCommandSent = ok
    pendingIncoming.irisError = reason
  end

  if INCOMING_ALARM then
    siren(true)
  end

  computer.beep(900, 0.15)
  computer.beep(700, 0.15)
  computer.beep(900, 0.15)

  log(
    "Connexion entrante depuis " ..
    (knownName and string.upper(knownName) or "ORIGINE INCONNUE") ..
    " [" .. safeToString(address) .. "]"
  )
end

local function installIncomingListener()
  if incomingListenerInstalled then
    return true
  end

  local ok, reason =
    event.listen("sgDialIn", incomingEventHandler)

  if ok then
    incomingListenerInstalled = true
    return true
  end

  log("Impossible d'installer l'ecoute sgDialIn : " ..
    safeToString(reason))

  return false, reason
end

local function removeIncomingListener()
  if incomingListenerInstalled then
    pcall(event.ignore, "sgDialIn", incomingEventHandler)
    incomingListenerInstalled = false
  end
end

local function waitForIrisState(expected, timeoutSeconds)
  local timeout = computer.uptime() + (timeoutSeconds or 10)

  while computer.uptime() < timeout do
    if getIrisState() == expected then
      return true
    end

    os.sleep(0.20)
  end

  return false
end

local function incomingConnectionScreen()
  if not pendingIncoming then
    return
  end

  local incoming = pendingIncoming
  pendingIncoming = nil

  -- remoteAddress() peut devenir disponible un peu après sgDialIn.
  if not incoming.address or incoming.address == "" then
    local timeout = computer.uptime() + 5

    while computer.uptime() < timeout do
      incoming.address = getRemoteAddress()

      if incoming.address and incoming.address ~= "" then
        break
      end

      os.sleep(0.20)
    end
  end

  incoming.address = normalizeAddress(incoming.address or "")
  incoming.name =
    incoming.name or findDestinationByAddress(incoming.address)

  while true do
    header()
    print("********************************")
    print("    ALERTE PORTE ENTRANTE")
    print("********************************")
    print()

    if incoming.name then
      print("ORIGINE : " .. string.upper(incoming.name))
    else
      print("ORIGINE : INCONNUE")
    end

    print("ADRESSE : " ..
      (incoming.address ~= "" and incoming.address or "NON RECUE"))

    local state, chevrons, direction = getGateState()

    print("ETAT    : " .. safeToString(state))
    print("CHEVRONS: " .. safeToString(chevrons))
    print("SENS    : " .. safeToString(direction))
    print("IRIS    : " .. safeToString(getIrisState()))
    print()

    if incoming.irisError then
      print("ATTENTION : fermeture automatique")
      print("de l'iris non confirmee.")
      print("Detail : " .. safeToString(incoming.irisError))
      print()
    end

    if state == "Idle" or state == "Offline" then
      emergencyAlarmStop()
      print("La connexion entrante est terminee.")
      log("Fin de connexion entrante [" ..
        safeToString(incoming.address) .. "]")
      waitForEnter()
      return
    end

    separator()
    print("1 - Ouvrir l'iris")
    print("2 - Maintenir l'iris ferme")
    print("3 - Fermer la connexion")
    print("4 - Actualiser")
    separator()
    print()
    io.write("Decision SGC > ")

    local choice = io.read()

    if choice == "1" then
      local ok, result, reason = pcall(gate.openIris)

      if not ok or result == nil then
        print()
        print("ECHEC D'OUVERTURE : " ..
          safeToString(ok and reason or result))
        pause(2)
      else
        waitForIrisState("Open", 10)
        emergencyAlarmStop()
        log("Iris ouvert pour connexion entrante depuis " ..
          safeToString(incoming.address))
      end

    elseif choice == "2" then
      closeIrisImmediately()
      emergencyAlarmStop()
      log("Iris maintenu ferme pour connexion entrante depuis " ..
        safeToString(incoming.address))
      print()
      print("IRIS MAINTENU FERME")
      print("Surveillance de la connexion...")
      pause(1)

    elseif choice == "3" then
      local ok, result, reason = pcall(gate.disconnect)

      emergencyAlarmStop()

      if not ok or result == nil then
        print()
        print("ECHEC DE DECONNEXION : " ..
          safeToString(ok and reason or result))
        pause(2)
      else
        log("Connexion entrante fermee manuellement depuis " ..
          safeToString(incoming.address))
        print()
        print("Commande de fermeture envoyee.")
        pause(1)
      end

    elseif choice == "4" then
      -- Le prochain passage de boucle réaffiche les données.
    else
      print()
      print("Commande inconnue.")
      pause(1)
    end
  end
end

local function getDestinationInfo(name)
  local key = normalizeName(name)
  local data = DESTINATION_DATA[key] or {}

  return {
    galaxy = data.galaxy or "INCONNUE",
    status = data.status or "NON DETERMINE",
    threat = data.threat or "INCONNU",
    notes = data.notes or "Aucune note disponible."
  }
end

local function sortedDestinationNames()
  local names = {}

  for name in pairs(ADDRESS_BOOK) do
    table.insert(names, tostring(name))
  end

  table.sort(names, function(a, b)
    return normalizeName(a) < normalizeName(b)
  end)

  return names
end

local function showDestinationFile(name)
  local address, resolvedName = resolveDestination(name)

  if not resolvedName then
    header()
    print("DESTINATION INCONNUE")
    waitForEnter()
    return
  end

  local info = getDestinationInfo(resolvedName)

  header()
  print("DOSSIER DE DESTINATION")
  separator()
  print("CODE     : " .. string.upper(resolvedName))
  print("ADRESSE  : " .. address)
  print("GALAXIE  : " .. info.galaxy)
  print("STATUT   : " .. info.status)
  print("MENACE   : " .. info.threat)
  print()
  print("NOTES")
  separator()
  print(info.notes)
  waitForEnter()
end

local function destinationDatabase()
  while true do
    header()
    print("BASE DE DONNEES PLANETAIRES")
    separator()

    local names = sortedDestinationNames()

    for index, name in ipairs(names) do
      local info = getDestinationInfo(name)

      print(
        tostring(index) .. " - " ..
        string.upper(name) .. " [" ..
        info.status .. " / " ..
        info.threat .. "]"
      )
    end

    print()
    print("0 - Retour")
    print()
    io.write("Dossier > ")

    local choice = io.read()

    if choice == "0" then
      return
    end

    local index = tonumber(choice)

    if index and names[index] then
      showDestinationFile(names[index])
    else
      print("Selection inconnue.")
      pause(1)
    end
  end
end

local function selectFromList(title, values)
  while true do
    header()
    print(title)
    separator()

    for index, value in ipairs(values) do
      print(tostring(index) .. " - " .. tostring(value))
    end

    print()
    print("0 - Annuler")
    print()
    io.write("Selection > ")

    local choice = io.read()

    if choice == "0" then
      return nil
    end

    local index = tonumber(choice)

    if index and values[index] then
      return values[index]
    end

    print("Selection inconnue.")
    pause(1)
  end
end

local function buildMission()
  local destination = selectFromList(
    "SELECTION DE LA DESTINATION",
    sortedDestinationNames()
  )

  if not destination then
    return nil
  end

  local team = selectFromList(
    "SELECTION DE L'EQUIPE",
    SG_TEAMS
  )

  if not team then
    return nil
  end

  local missionType = selectFromList(
    "TYPE DE MISSION",
    MISSION_TYPES
  )

  if not missionType then
    return nil
  end

  local address, resolvedName =
    resolveDestination(destination)
  local info = getDestinationInfo(resolvedName)

  header()
  print("AUTORISATION DE MISSION")
  separator()
  print("DESTINATION : " ..
    string.upper(resolvedName))
  print("ADRESSE     : " .. address)
  print("EQUIPE      : " .. team)
  print("MISSION     : " .. missionType)
  print("STATUT      : " .. info.status)
  print("MENACE      : " .. info.threat)
  print()
  print("1 - Autoriser et composer")
  print("2 - Annuler")
  print()
  io.write("Autorisation > ")

  if io.read() ~= "1" then
    missionLog(
      "MISSION ANNULEE | " .. team ..
      " | " .. string.upper(resolvedName) ..
      " | " .. missionType
    )
    return nil
  end

  return {
    destination = resolvedName,
    address = address,
    team = team,
    missionType = missionType,
    status = info.status,
    threat = info.threat
  }
end

local function showAddressBook()
  header()
  print("CARNET D'ADRESSES")
  separator()

  local names = sortedDestinationNames()

  if #names == 0 then
    print("Le carnet est vide.")
    print()
    print("Ajoute tes destinations dans ADDRESS_BOOK")
    print("au debut du fichier stargate.lua.")
  else
    for _, name in ipairs(names) do
      print(string.upper(name) .. " : " ..
        safeToString(ADDRESS_BOOK[name]))
    end
  end

  waitForEnter()
end

local function validateAddress(address)
  if address == "" then
    return false, "Adresse vide"
  end

  -- SGCraft utilise généralement 7 ou 9 symboles
  if #address ~= 7 and #address ~= 9 then
    return false,
      "L'adresse doit contenir 7 ou 9 caracteres"
  end

  return true
end

------------------------------------------------------------
-- AFFICHAGE DU STATUT
------------------------------------------------------------

local function showStatus()
  header()

  local state, chevrons, direction = getGateState()
  local energy, energyError = getEnergy()
  local localAddress = getLocalAddress()
  local remoteAddress = getRemoteAddress()

  print("DIAGNOSTIC DE LA PORTE")
  separator()

  print("Etat          : " .. safeToString(state))
  print("Chevrons      : " .. safeToString(chevrons))
  print("Direction     : " .. safeToString(direction))
  print("Adresse locale: " .. safeToString(localAddress))
  print("Adresse dist. : " .. safeToString(remoteAddress))
  print("Iris          : " .. safeToString(getIrisState()))

  if energy then
    print("Energie       : " .. tostring(energy) .. " SU")
  else
    print("Energie       : INCONNUE")
    print("Raison        : " .. safeToString(energyError))
  end

  print()
  print("Interface     : " ..
    safeToString(gateAddress and gateAddress:sub(1, 8)))

  if alarm then
    print("Alarme        : DETECTEE")
    print("Etat alarme   : " ..
      (alarmActive and "ACTIVE" or "ARRETEE"))
  else
    print("Alarme        : NON DETECTEE")
  end

  waitForEnter()
end

------------------------------------------------------------
-- OUVERTURE DE LA PORTE
------------------------------------------------------------

local function openGate(rawAddress, mission)
  header()

  local address, destinationName = resolveDestination(rawAddress)
  local valid, validationError = validateAddress(address)

  if not valid then
    print("ADRESSE INVALIDE")
    print()
    print(validationError)
    print("Adresse recue : " .. safeToString(address))

    log("Adresse invalide : " .. safeToString(address))
    waitForEnter()
    return false
  end

  if not gate then
    print("ERREUR : PORTE NON DETECTEE")
    waitForEnter()
    return false
  end

  if not gate.dial then
    print("ERREUR API")
    print("La methode gate.dial est introuvable.")
    print()
    print("Verifie que l'interface OpenComputers")
    print("de SGCraft est bien utilisee.")

    log("Methode dial absente")
    waitForEnter()
    return false
  end

  local state = getGateState()

  if state ~= "Idle" then
    print("COMPOSITION REFUSEE")
    print()
    print("La porte n'est pas disponible.")
    print("Etat actuel : " .. safeToString(state))

    log("Composition refusee vers " ..
      address .. ", etat : " .. safeToString(state))

    waitForEnter()
    return false
  end

  if destinationName then
    print("DESTINATION : " ..
      string.upper(destinationName))
    print("ADRESSE     : " .. address)
  else
    print("DESTINATION : " .. address)
  end

  if mission then
    print("EQUIPE      : " .. mission.team)
    print("MISSION     : " .. mission.missionType)
    print("MENACE      : " .. mission.threat)
  end

  separator()
  print("Verification de l'adresse...")

  local requiredEnergy, costError = getDialCost(address)

  if not requiredEnergy then
    print()
    print("DESTINATION REFUSEE")
    print("La porte ne peut pas calculer le trajet.")
    print()
    print("Detail : " .. safeToString(costError))

    log("Adresse refusee " ..
      address .. " : " .. safeToString(costError))

    waitForEnter()
    return false
  end

  local availableEnergy, energyError = getEnergy()

  print("Energie necessaire : " ..
    tostring(requiredEnergy) .. " SU")

  if availableEnergy then
    print("Energie disponible : " ..
      tostring(availableEnergy) .. " SU")

    if availableEnergy < requiredEnergy then
      print()
      print("ENERGIE INSUFFISANTE")
      print("Composition annulee.")

      log("Energie insuffisante vers " ..
        address .. " : " ..
        tostring(availableEnergy) .. "/" ..
        tostring(requiredEnergy) .. " SU")

      waitForEnter()
      return false
    end
  else
    print("Energie disponible : INCONNUE")
    print("Detail : " .. safeToString(energyError))
    print()
    print("Composition autorisee sans controle")
    print("energetique.")
  end

  print()
  print("ACTIVATION DE L'ALARME")
  siren(true)

  log("Debut de composition vers " .. address)

  if mission then
    missionLog(
      "DEPART AUTORISE | " .. mission.team ..
      " | " .. string.upper(mission.destination) ..
      " [" .. address .. "]" ..
      " | " .. mission.missionType ..
      " | MENACE " .. mission.threat
    )
  end

  print("Lancement de la sequence...")

  -- Le pcall empêche une erreur de composition
  -- de faire planter tout le programme.
  local dialOk, dialResult = pcall(gate.dial, address)

  if not dialOk then
    emergencyAlarmStop()

    print()
    print("ECHEC DE COMPOSITION")
    print()
    print("SGCraft a refuse la commande :")
    print(safeToString(dialResult))

    log("Echec de composition vers " ..
      address .. " : " .. safeToString(dialResult))

    waitForEnter()
    return false
  end

  print("Commande acceptee.")
  print()

  local startTime = computer.uptime()
  local alarmStopTime = startTime + ALARM_DURATION
  local timeoutTime = startTime + DIAL_TIMEOUT
  local previousState = nil
  local previousChevrons = -1
  local connected = false

  while computer.uptime() < timeoutTime do
    local currentState, chevrons, direction =
      getGateState()

    chevrons = tonumber(chevrons) or 0

    if currentState ~= previousState
       or chevrons ~= previousChevrons then

      local elapsed =
        math.floor(computer.uptime() - startTime)

      if chevrons > previousChevrons and chevrons > 0 then
        print(
          "[" .. elapsed .. "s] CHEVRON " ..
          tostring(chevrons) .. " ENGAGE"
        )
      end

      if currentState ~= previousState then
        print(
          "[" .. elapsed .. "s] ETAT : " ..
          safeToString(currentState) ..
          " | DIRECTION : " ..
          safeToString(direction)
        )
      end

      log(
        "Composition " .. address ..
        " - Etat : " .. safeToString(currentState) ..
        ", chevrons : " .. tostring(chevrons)
      )

      previousState = currentState
      previousChevrons = chevrons
    end

    -- Arrêt automatique de l'alarme après le délai choisi
    if ALARM_DURATION > 0
       and alarmActive
       and computer.uptime() >= alarmStopTime then
      siren(false)
      print("Alarme de depart arretee.")
    end

    if currentState == "Connected" then
      connected = true
      break
    end

    -- La porte est revenue au repos avant la connexion
    if currentState == "Idle"
       and computer.uptime() - startTime > 2 then
      break
    end

    if currentState == "Offline"
       or currentState == "ERROR"
       or currentState == "API_INCOMPATIBLE" then
      break
    end

    os.sleep(0.25)
  end

  -- Arrêt obligatoire de la sirène quelle que soit l'issue
  emergencyAlarmStop()

  print()

  if connected then
    print("================================")
    print("       VORTEX STABILISE")
    print("     CONNEXION CONFIRMEE")
    print("================================")

    log("Connexion etablie vers " .. address)

    if mission then
      missionLog(
        "VORTEX STABILISE | " .. mission.team ..
        " | " .. string.upper(mission.destination) ..
        " | " .. mission.missionType
      )
    end

    waitForEnter()
    return true
  end

  local finalState = getGateState()

  if computer.uptime() >= timeoutTime then
    print("DELAI DE COMPOSITION DEPASSE")
  else
    print("COMPOSITION INTERROMPUE")
  end

  print("Dernier etat : " .. safeToString(finalState))

  log("Composition non aboutie vers " ..
    address .. ", dernier etat : " ..
    safeToString(finalState))

  if mission then
    missionLog(
      "ECHEC DEPART | " .. mission.team ..
      " | " .. string.upper(mission.destination) ..
      " | ETAT " .. safeToString(finalState)
    )
  end

  waitForEnter()
  return false
end

------------------------------------------------------------
-- FERMETURE DE LA PORTE
------------------------------------------------------------

local function closeGate()
  header()

  emergencyAlarmStop()

  if not gate then
    print("ERREUR : PORTE NON DETECTEE")
    waitForEnter()
    return false
  end

  if not gate.disconnect then
    print("ERREUR API")
    print("La methode disconnect est introuvable.")

    log("Methode disconnect absente")
    waitForEnter()
    return false
  end

  local state = getGateState()

  print("Etat actuel : " .. safeToString(state))
  print()
  print("Envoi de la commande de fermeture...")

  local ok, result = pcall(gate.disconnect)

  if not ok then
    print()
    print("ECHEC DE FERMETURE")
    print(safeToString(result))

    log("Erreur de fermeture : " ..
      safeToString(result))

    waitForEnter()
    return false
  end

  print("Commande acceptee.")
  log("Fermeture manuelle demandee")

  local timeout = computer.uptime() + 20

  while computer.uptime() < timeout do
    local currentState = getGateState()

    if currentState == "Idle" then
      print("Porte fermee.")
      log("Porte revenue a l'etat Idle")
      waitForEnter()
      return true
    end

    os.sleep(0.25)
  end

  print("La porte n'a pas confirme sa fermeture.")
  waitForEnter()
  return false
end

------------------------------------------------------------
-- AFFICHAGE DES JOURNAUX
------------------------------------------------------------

local function showLogs()
  header()
  print("JOURNAL DU SGC")
  separator()

  initializeLog()

  local file = io.open(LOG_FILE, "r")

  if not file then
    print("Aucun journal disponible.")
    waitForEnter()
    return
  end

  local lines = {}

  for line in file:lines() do
    table.insert(lines, line)

    -- Garde uniquement les 15 dernières lignes
    if #lines > 15 then
      table.remove(lines, 1)
    end
  end

  file:close()

  if #lines == 0 then
    print("Le journal est vide.")
  else
    for _, line in ipairs(lines) do
      print(line)
    end
  end

  waitForEnter()
end

local function showMissionLogs()
  header()
  print("JOURNAL DES MISSIONS")
  separator()

  initializeLog()

  local file = io.open(MISSION_LOG_FILE, "r")

  if not file then
    print("Aucune mission enregistree.")
    waitForEnter()
    return
  end

  local lines = {}

  for line in file:lines() do
    table.insert(lines, line)

    if #lines > 15 then
      table.remove(lines, 1)
    end
  end

  file:close()

  if #lines == 0 then
    print("Le journal des missions est vide.")
  else
    for _, line in ipairs(lines) do
      print(line)
    end
  end

  waitForEnter()
end

------------------------------------------------------------
-- DIAGNOSTIC DES MÉTHODES
------------------------------------------------------------

local function showMethods()
  header()
  print("METHODES DE L'INTERFACE STARGATE")
  separator()

  if not gateAddress then
    print("Aucune interface Stargate detectee.")
    waitForEnter()
    return
  end

  local methods = component.methods(gateAddress)
  local names = {}

  for name in pairs(methods) do
    table.insert(names, name)
  end

  table.sort(names)

  for _, name in ipairs(names) do
    print("- " .. name)
  end

  waitForEnter()
end

------------------------------------------------------------
-- MENU PRINCIPAL
------------------------------------------------------------

local function main()
  initializeLog()

  findGate()
  findAlarm()

  if gate then
    installIncomingListener()
  end

  -- Au démarrage, on arrête une éventuelle alarme
  -- restée active après un ancien plantage.
  emergencyAlarmStop()

  log("Demarrage du systeme SGC")

  if not gate then
    header()
    print("ERREUR CRITIQUE")
    print()
    print("Aucune interface Stargate detectee.")
    print()
    print("Verifie :")
    print("- l'interface OpenComputers SGCraft ;")
    print("- les cables OpenComputers ;")
    print("- l'alimentation de l'ordinateur.")
    print()

    waitForEnter()
    return
  end

  while true do
    if pendingIncoming then
      incomingConnectionScreen()
    end

    header()

    local state, chevrons, direction = getGateState()
    local energy = getEnergy()
    local localAddress = getLocalAddress()
    local remoteAddress = getRemoteAddress()

    print("PORTE    : " .. safeToString(state))
    print("CHEVRONS : " .. safeToString(chevrons))
    print("DIRECTION: " .. safeToString(direction))
    print("ADRESSE  : " .. safeToString(localAddress))
    print("DISTANTE : " .. safeToString(remoteAddress))
    print("IRIS     : " .. safeToString(getIrisState()))

    if energy then
      print("ENERGIE  : " .. tostring(energy) .. " SU")
    else
      print("ENERGIE  : INCONNUE")
    end

    if alarm then
      print("ALARME   : " ..
        (alarmActive and "ACTIVE" or "PRETE"))
    else
      print("ALARME   : NON DETECTEE")
    end

    print()
    separator()
    print("1 - Autoriser une mission SG")
    print("2 - Composition manuelle")
    print("3 - Fermer la porte")
    print("4 - Controler l'iris")
    print("5 - Base de donnees planetaires")
    print("6 - Carnet d'adresses")
    print("7 - Journal des missions")
    print("8 - Journal technique")
    print("9 - Diagnostic complet")
    print("10 - Methodes SGCraft")
    print("11 - Arret d'urgence de l'alarme")
    print("12 - Quitter")
    separator()
    print()

    io.write("Commande SGC > ")
    local choice = io.read()

    if pendingIncoming then
      incomingConnectionScreen()

    elseif choice == "1" then
      local mission = buildMission()

      if mission then
        openGate(mission.destination, mission)
      end

    elseif choice == "2" then
      header()
      print("COMPOSITION MANUELLE")
      separator()
      print()
      print("Entre un nom du carnet ou une adresse.")
      print()
      io.write("Destination > ")

      local destination = io.read()
      openGate(destination)

    elseif choice == "3" then
      closeGate()

    elseif choice == "4" then
      irisMenu()

    elseif choice == "5" then
      destinationDatabase()

    elseif choice == "6" then
      showAddressBook()

    elseif choice == "7" then
      showMissionLogs()

    elseif choice == "8" then
      showLogs()

    elseif choice == "9" then
      showStatus()

    elseif choice == "10" then
      showMethods()

    elseif choice == "11" then
      header()
      emergencyAlarmStop()

      print("ARRET D'URGENCE")
      print()
      print("La commande d'arret de l'alarme")
      print("a ete envoyee.")

      log("Arret d'urgence de l'alarme")
      waitForEnter()

    elseif choice == "12" then
      removeIncomingListener()
      emergencyAlarmStop()
      log("Arret normal du systeme SGC")

      header()
      print("Arret du systeme SGC.")
      print("Alarme securisee.")
      return

    else
      print()
      print("Commande inconnue.")
      pause(1)
    end
  end
end

------------------------------------------------------------
-- GESTIONNAIRE D'ERREUR CRITIQUE
------------------------------------------------------------

local function emergencyCleanup(errorMessage)
  removeIncomingListener()
  emergencyAlarmStop()

  print()
  print("================================")
  print("       ERREUR CRITIQUE SGC")
  print("================================")
  print()
  print(safeToString(errorMessage))
  print()
  print("L'alarme a recu une commande")
  print("d'arret d'urgence.")

  log("ERREUR CRITIQUE : " ..
    safeToString(errorMessage))

  return errorMessage
end

------------------------------------------------------------
-- LANCEMENT PROTÉGÉ
------------------------------------------------------------

xpcall(main, emergencyCleanup)

-- Deuxième sécurité à la sortie du programme
emergencyAlarmStop()
