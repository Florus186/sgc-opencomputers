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
local DATA_DIRECTORY = "/home/sgc"
local TEAM_DATABASE_FILE = DATA_DIRECTORY .. "/teams.db"
local DEFCON_DATABASE_FILE = DATA_DIRECTORY .. "/defcon.db"
local DEFCON_LOG_FILE = LOG_DIRECTORY .. "/defcon.log"
local INTELLIGENCE_DATABASE_FILE = DATA_DIRECTORY .. "/intelligence.db"
local ROLES_DATABASE_FILE = DATA_DIRECTORY .. "/roles.db"
local USERS_DATABASE_FILE = DATA_DIRECTORY .. "/users.db"
local SECURITY_LOG_FILE = LOG_DIRECTORY .. "/security.log"

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

-- Système IDC.
-- Matériel recommandé : une paire de Linked Cards OpenComputers.
-- Le programme accepte aussi une carte réseau sur le port indiqué.
local IDC_ENABLED = false
local IDC_NETWORK_PORT = 1701
local IDC_SECURITY_MODE = "CONFIRMATION"
-- Modes possibles :
-- "AUTOMATIQUE"   : ouvre l'iris dès qu'un IDC valide est reçu.
-- "CONFIRMATION"  : demande l'accord de l'opérateur.
-- "VERROUILLE"    : aucune ouverture automatique.

local IDC_CODES = {
  ["SG-1"] = "1701",
  ["SG-2"] = "2202",
  ["SG-3"] = "3303",
  ["SG-4"] = "4404"
}

-- Carnet d'adresses.
-- Remplace les exemples par les vraies adresses de tes portes.
-- Les noms sont saisis sans distinction entre majuscules/minuscules.
local ADDRESS_BOOK = {
  Terre = "ZFVS-MY6-DJ",
  Abydos = "BFVG-A4I-W7",
  Chulak = "3FF2-BPI-ER",
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

-- Etat persistant des equipes SG.
local teamState = {}

-- Déclarations anticipées, définies plus bas.
local normalizeAddress
local waitForIrisState
local siren
local closeIrisImmediately
local recordPlanetVisit
local recordPlanetReturn

-- Communication IDC : Linked Card ("tunnel") ou carte réseau ("modem").
local idcTransport = nil
local idcTransportType = nil
local idcListenerInstalled = false
local latestIDC = nil
local idcFailureCount = 0

local DEFCON_LEVELS = {
  VERT = 1,
  JAUNE = 2,
  ROUGE = 3,
  NOIR = 4
}

local defconLevel = "VERT"
local defconReason = "Situation normale"
local defconChangedAt = 0

-- Renseignements persistants accumulés au fil des missions.
local intelligenceData = {}

-- Personnel et droits logiciels.
-- Les identifiants USR sont prêts pour les futures cartes OpenSecurity.
local personnelRoles = {}
local personnelUsers = {}
local currentUser = nil

local DEFAULT_ROLES = {
  GENERAL = {
    label = "GENERAL",
    permissions = {
      dashboard = true,
      operations = true,
      missions = true,
      dial = true,
      close_gate = true,
      iris = true,
      idc = true,
      intelligence_view = true,
      intelligence_edit = true,
      address_book = true,
      teams = true,
      mission_logs = true,
      technical_logs = true,
      diagnostics = true,
      sgcraft_methods = true,
      alarm_stop = true,
      defcon_view = true,
      defcon_change = true,
      defcon_black = true,
      personnel_view = true,
      personnel_switch = true,
      personnel_admin = true,
      shutdown = true
    }
  },

  CHIEF_OPERATOR = {
    label = "CHEF OPERATEUR",
    permissions = {
      dashboard = true,
      operations = true,
      missions = true,
      dial = true,
      close_gate = true,
      iris = true,
      idc = true,
      intelligence_view = true,
      intelligence_edit = true,
      address_book = true,
      teams = true,
      mission_logs = true,
      technical_logs = true,
      diagnostics = true,
      sgcraft_methods = true,
      alarm_stop = true,
      defcon_view = true,
      defcon_change = true,
      personnel_view = true,
      personnel_switch = true,
      shutdown = true
    }
  },

  OPERATOR = {
    label = "OPERATEUR",
    permissions = {
      dashboard = true,
      operations = true,
      dial = true,
      close_gate = true,
      iris = true,
      idc = true,
      intelligence_view = true,
      address_book = true,
      mission_logs = true,
      diagnostics = true,
      alarm_stop = true,
      defcon_view = true,
      personnel_view = true,
      personnel_switch = true,
      shutdown = true
    }
  }
}

local DEFAULT_USERS = {
  {
    id = "USR001",
    login = "HAMMOND",
    name = "George Hammond",
    rank = "Major General",
    role = "GENERAL",
    enabled = true
  },
  {
    id = "USR002",
    login = "WALTER",
    name = "Walter Harriman",
    rank = "Master Sergeant",
    role = "CHIEF_OPERATOR",
    enabled = true
  },
  {
    id = "USR003",
    login = "PIERCE",
    name = "Nathan Pierce",
    rank = "Technical Sergeant",
    role = "OPERATOR",
    enabled = true
  }
}

-- Interface graphique légère.
local gpu = component.isAvailable("gpu") and component.gpu or nil
local UI_COLORS = {
  normal = 0xFFFFFF,
  muted = 0xAAAAAA,
  green = 0x55FF55,
  yellow = 0xFFFF55,
  red = 0xFF5555,
  cyan = 0x55FFFF,
  title = 0x55AAFF
}

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

local function setTextColor(color)
  if gpu and gpu.setForeground then
    pcall(gpu.setForeground, color or UI_COLORS.normal)
  end
end

local function resetTextColor()
  setTextColor(UI_COLORS.normal)
end

local function printColored(textValue, color)
  setTextColor(color)
  print(textValue)
  resetTextColor()
end

local function alertColor()
  if defconLevel == "VERT" then
    return UI_COLORS.green
  elseif defconLevel == "JAUNE" then
    return UI_COLORS.yellow
  end

  return UI_COLORS.red
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

local function currentTimestamp()
  local value = nil

  if os.time then
    local ok, result = pcall(os.time)

    if ok then
      value = tonumber(result)
    end
  end

  if value then
    if value > 100000000000 then
      value = math.floor(value / 1000)
    end

    return math.floor(value)
  end

  return math.floor(computer.uptime())
end

local function formatDuration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))

  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local remaining = seconds % 60

  return string.format(
    "%02d:%02d:%02d",
    hours,
    minutes,
    remaining
  )
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


local function securityTimestamp()
  if os.date then
    return os.date("%Y-%m-%d %H:%M:%S")
  end

  return "UPTIME " .. math.floor(computer.uptime())
end

local function securityLog(action, details)
  initializeLog()
  local file = io.open(SECURITY_LOG_FILE, "a")

  if not file then
    return false
  end

  local actor = "SYSTEME"
  local actorId = "SYS000"
  local role = "SYSTEME"

  if currentUser then
    actor = currentUser.name
    actorId = currentUser.id
    role = currentUser.role
  end

  file:write(
    "[" .. securityTimestamp() .. "] " ..
    actorId .. " | " .. actor .. " | " .. role ..
    " | " .. tostring(action or "EVENEMENT") ..
    " | " .. tostring(details or "") .. "\n"
  )
  file:close()
  return true
end

local function clonePermissions(source)
  local target = {}

  for permission, allowed in pairs(source or {}) do
    target[permission] = allowed == true
  end

  return target
end

local function initializePersonnelDefaults()
  personnelRoles = {}

  for roleId, role in pairs(DEFAULT_ROLES) do
    personnelRoles[roleId] = {
      label = role.label,
      permissions = clonePermissions(role.permissions)
    }
  end

  personnelUsers = {}

  for _, user in ipairs(DEFAULT_USERS) do
    personnelUsers[user.id] = {
      id = user.id,
      login = user.login,
      name = user.name,
      rank = user.rank,
      role = user.role,
      enabled = user.enabled == true
    }
  end
end

local function sortedPermissionNames(permissions)
  local names = {}

  for permission, allowed in pairs(permissions or {}) do
    if allowed then
      table.insert(names, permission)
    end
  end

  table.sort(names)
  return names
end

local function saveRoles()
  ensureDataDirectory()
  local file = io.open(ROLES_DATABASE_FILE, "w")

  if not file then
    return false
  end

  local roleNames = {}

  for roleId in pairs(personnelRoles) do
    table.insert(roleNames, roleId)
  end

  table.sort(roleNames)

  for _, roleId in ipairs(roleNames) do
    local role = personnelRoles[roleId]

    file:write(
      roleId .. "|" ..
      tostring(role.label or roleId) .. "|" ..
      table.concat(
        sortedPermissionNames(role.permissions),
        ","
      ) .. "\n"
    )
  end

  file:close()
  return true
end

local function saveUsers()
  ensureDataDirectory()
  local file = io.open(USERS_DATABASE_FILE, "w")

  if not file then
    return false
  end

  local userIds = {}

  for userId in pairs(personnelUsers) do
    table.insert(userIds, userId)
  end

  table.sort(userIds)

  for _, userId in ipairs(userIds) do
    local user = personnelUsers[userId]

    file:write(table.concat({
      user.id,
      user.login,
      user.name,
      user.rank,
      user.role,
      user.enabled and "1" or "0"
    }, "|") .. "\n")
  end

  file:close()
  return true
end

local function loadRoles()
  personnelRoles = {}
  local file = io.open(ROLES_DATABASE_FILE, "r")

  if not file then
    initializePersonnelDefaults()
    saveRoles()
    return
  end

  for line in file:lines() do
    local roleId, label, permissionList =
      line:match("^([^|]+)|([^|]*)|(.*)$")

    if roleId and roleId ~= "" then
      local permissions = {}

      for permission in
        tostring(permissionList):gmatch("[^,]+") do
        permissions[permission] = true
      end

      personnelRoles[roleId] = {
        label = label ~= "" and label or roleId,
        permissions = permissions
      }
    end
  end

  file:close()

  if not next(personnelRoles) then
    initializePersonnelDefaults()
    saveRoles()
  end
end

local function loadUsers()
  personnelUsers = {}
  local file = io.open(USERS_DATABASE_FILE, "r")

  if not file then
    for _, user in ipairs(DEFAULT_USERS) do
      personnelUsers[user.id] = {
        id = user.id,
        login = user.login,
        name = user.name,
        rank = user.rank,
        role = user.role,
        enabled = user.enabled == true
      }
    end

    saveUsers()
    return
  end

  for line in file:lines() do
    local fields = {}

    for field in (line .. "|"):gmatch("(.-)|") do
      table.insert(fields, field)
    end

    if fields[1] and fields[1] ~= "" then
      personnelUsers[fields[1]] = {
        id = fields[1],
        login = fields[2] or fields[1],
        name = fields[3] or fields[1],
        rank = fields[4] or "",
        role = fields[5] or "OPERATOR",
        enabled = fields[6] ~= "0"
      }
    end
  end

  file:close()

  if not next(personnelUsers) then
    initializePersonnelDefaults()
    saveUsers()
  end
end

local function loadPersonnel()
  loadRoles()
  loadUsers()
end

local function hasPermission(permission)
  if not currentUser or not currentUser.enabled then
    return false
  end

  local role = personnelRoles[currentUser.role]

  return role and role.permissions and
    role.permissions[permission] == true
end

local function denyPermission(permission)
  header()
  printColored("ACCES REFUSE", UI_COLORS.red)
  separator()
  print("Permission requise : " .. tostring(permission))
  print()
  print(
    "Utilisateur : " ..
    (currentUser and currentUser.name or "AUCUN")
  )
  print(
    "Role        : " ..
    (currentUser and currentUser.role or "AUCUN")
  )
  print()
  securityLog("ACCES REFUSE", permission)
  waitForEnter()
end

local function requirePermission(permission)
  if hasPermission(permission) then
    return true
  end

  denyPermission(permission)
  return false
end

local function orderedUsers()
  local users = {}

  for _, user in pairs(personnelUsers) do
    table.insert(users, user)
  end

  table.sort(users, function(a, b)
    return a.id < b.id
  end)

  return users
end

local function findUserByCredential(value)
  local token =
    tostring(value or ""):upper():gsub("%s+", "")

  for _, user in pairs(personnelUsers) do
    if user.id:upper() == token or
       user.login:upper() == token then
      return user
    end
  end

  return nil
end

local function loginScreen(allowCancel)
  while true do
    clear()
    printColored("================================", UI_COLORS.title)
    printColored("       STARGATE COMMAND", UI_COLORS.title)
    printColored("   CONTROLE D'ACCES OPERATEUR", UI_COLORS.cyan)
    printColored("================================", UI_COLORS.title)
    print()

    local users = orderedUsers()

    for index, user in ipairs(users) do
      local role = personnelRoles[user.role]
      local state = user.enabled and "ACTIF" or "DESACTIVE"

      print(
        tostring(index) .. " - " ..
        user.rank .. " " .. user.name
      )
      print(
        "    " .. user.id .. " / " ..
        safeToString(role and role.label or user.role) ..
        " / " .. state
      )
    end

    print()
    print("Numero, identifiant USR ou login.")

    if allowCancel then
      print("0 - Annuler")
    end

    print()
    io.write("Identification > ")
    local value = io.read()

    if allowCancel and value == "0" then
      return false
    end

    local selected = nil
    local index = tonumber(value)

    if index and users[index] then
      selected = users[index]
    else
      selected = findUserByCredential(value)
    end

    if not selected then
      print()
      print("Identifiant inconnu.")
      securityLog("ECHEC CONNEXION", tostring(value))
      pause(1)
    elseif not selected.enabled then
      print()
      print("Profil desactive.")
      securityLog(
        "ECHEC CONNEXION",
        selected.id .. " PROFIL DESACTIVE"
      )
      pause(1)
    else
      local previous =
        currentUser and currentUser.id or "AUCUN"

      currentUser = selected
      securityLog(
        "CONNEXION",
        "SESSION PRECEDENTE " .. previous
      )

      clear()
      printColored("IDENTIFICATION ACCEPTEE", UI_COLORS.green)
      print()
      print("Bienvenue,")
      print(selected.rank .. " " .. selected.name)
      print()
      print("Identifiant : " .. selected.id)
      print(
        "Role        : " ..
        safeToString(
          personnelRoles[selected.role] and
          personnelRoles[selected.role].label or
          selected.role
        )
      )
      pause(2)
      return true
    end
  end
end

local function showUserProfile(user)
  local role = personnelRoles[user.role]
  local permissions =
    sortedPermissionNames(role and role.permissions or {})

  header()
  print("DOSSIER PERSONNEL")
  separator()
  print("ID       : " .. user.id)
  print("LOGIN    : " .. user.login)
  print("NOM      : " .. user.name)
  print("GRADE    : " .. user.rank)
  print("ROLE     : " ..
    safeToString(role and role.label or user.role))
  print("ETAT     : " ..
    (user.enabled and "ACTIF" or "DESACTIVE"))
  print()
  print("PERMISSIONS")
  separator()

  for _, permission in ipairs(permissions) do
    print("+ " .. permission)
  end

  waitForEnter()
end

local function showSecurityLogs()
  if not requirePermission("personnel_view") then
    return
  end

  header()
  print("JOURNAL DE SECURITE")
  separator()

  local file = io.open(SECURITY_LOG_FILE, "r")

  if not file then
    print("Aucun evenement de securite.")
    waitForEnter()
    return
  end

  local lines = {}

  for line in file:lines() do
    table.insert(lines, line)

    if #lines > 35 then
      table.remove(lines, 1)
    end
  end

  file:close()

  for _, line in ipairs(lines) do
    print(line)
  end

  waitForEnter()
end

local function personnelMenu()
  if not requirePermission("personnel_view") then
    return
  end

  while true do
    header()
    printColored("PERSONNEL SGC", UI_COLORS.cyan)
    separator()
    print("1 - Changer d'operateur")
    print("2 - Consulter les profils")
    print("3 - Consulter les roles")
    print("4 - Journal de securite")
    print("5 - Sauvegarder utilisateurs et roles")
    print("0 - Retour")
    print()
    io.write("Personnel > ")

    local choice = io.read()

    if choice == "0" then
      return

    elseif choice == "1" then
      if requirePermission("personnel_switch") then
        loginScreen(true)
      end

    elseif choice == "2" then
      local users = orderedUsers()

      header()
      print("PROFILS DU PERSONNEL")
      separator()

      for index, user in ipairs(users) do
        print(
          tostring(index) .. " - " ..
          user.id .. " | " ..
          user.rank .. " " .. user.name ..
          " | " .. user.role
        )
      end

      print()
      io.write("Profil (0 retour) > ")
      local index = tonumber(io.read())

      if index and index > 0 and users[index] then
        showUserProfile(users[index])
      end

    elseif choice == "3" then
      header()
      print("ROLES ET AUTORISATIONS")
      separator()

      local roleIds = {}

      for roleId in pairs(personnelRoles) do
        table.insert(roleIds, roleId)
      end

      table.sort(roleIds)

      for _, roleId in ipairs(roleIds) do
        local role = personnelRoles[roleId]
        print()
        print(roleId .. " - " .. role.label)

        for _, permission in ipairs(
          sortedPermissionNames(role.permissions)
        ) do
          print("  + " .. permission)
        end
      end

      waitForEnter()

    elseif choice == "4" then
      showSecurityLogs()

    elseif choice == "5" then
      if requirePermission("personnel_admin") then
        saveRoles()
        saveUsers()
        securityLog(
          "SAUVEGARDE PERSONNEL",
          ROLES_DATABASE_FILE .. " / " ..
          USERS_DATABASE_FILE
        )
        print()
        print("Fichiers sauvegardes :")
        print(ROLES_DATABASE_FILE)
        print(USERS_DATABASE_FILE)
        waitForEnter()
      end

    else
      print("Commande inconnue.")
      pause(1)
    end
  end
end

local function defconTimestamp()
  if os.date then
    return os.date("%Y-%m-%d %H:%M:%S")
  end

  return "UPTIME " .. math.floor(computer.uptime())
end

local function defconLog(message)
  initializeLog()

  local file = io.open(DEFCON_LOG_FILE, "a")

  if file then
    file:write("[" .. defconTimestamp() .. "] " ..
      tostring(message) .. "\n")
    file:close()
  end
end

local function saveDefcon()
  if not filesystem.exists(DATA_DIRECTORY) then
    filesystem.makeDirectory(DATA_DIRECTORY)
  end

  local file = io.open(DEFCON_DATABASE_FILE, "w")

  if not file then
    log("Impossible de sauvegarder l'état DEFCON")
    return false
  end

  file:write("level=" .. tostring(defconLevel) .. "\n")
  file:write("reason=" ..
    tostring(defconReason):gsub("\n", " ") .. "\n")
  file:write("changedAt=" ..
    tostring(defconChangedAt or 0) .. "\n")
  file:write("idcFailures=" ..
    tostring(idcFailureCount or 0) .. "\n")
  file:close()
  return true
end

local function loadDefcon()
  local file = io.open(DEFCON_DATABASE_FILE, "r")

  if not file then
    defconLevel = "VERT"
    defconReason = "Situation normale"
    defconChangedAt = currentTimestamp()
    idcFailureCount = 0
    saveDefcon()
    return
  end

  for line in file:lines() do
    local key, value = line:match("^([^=]+)=(.*)$")

    if key == "level" and DEFCON_LEVELS[value] then
      defconLevel = value
    elseif key == "reason" and value ~= "" then
      defconReason = value
    elseif key == "changedAt" then
      defconChangedAt = tonumber(value) or 0
    elseif key == "idcFailures" then
      idcFailureCount = tonumber(value) or 0
    end
  end

  file:close()
end

local function defconAtLeast(level)
  return (DEFCON_LEVELS[defconLevel] or 1) >=
    (DEFCON_LEVELS[level] or 1)
end

local function setDefcon(level, reason, source)
  level = tostring(level or ""):upper()

  if not DEFCON_LEVELS[level] then
    return false, "Niveau DEFCON inconnu"
  end

  local previous = defconLevel
  defconLevel = level
  defconReason = tostring(reason or "Aucun motif communiqué")
  defconChangedAt = currentTimestamp()

  local message =
    "DEFCON " .. previous .. " -> " .. defconLevel ..
    " | " .. defconReason ..
    " | SOURCE " .. tostring(source or "OPERATEUR")

  defconLog(message)
  missionLog(message)
  log(message)
  securityLog("CHANGEMENT DEFCON", message)
  saveDefcon()

  if defconLevel == "ROUGE" then
    IDC_SECURITY_MODE = "CONFIRMATION"
  elseif defconLevel == "NOIR" then
    IDC_SECURITY_MODE = "VERROUILLE"

    if closeIrisImmediately then
      closeIrisImmediately()
    end

    if siren then
      siren(true)
    end
  end

  return true
end

local function registerSecurityIncident(reason, severity)
  severity = tostring(severity or "JAUNE"):upper()

  if severity == "NOIR" then
    setDefcon("NOIR", reason, "AUTOMATIQUE")
  elseif severity == "ROUGE" then
    if not defconAtLeast("ROUGE") then
      setDefcon("ROUGE", reason, "AUTOMATIQUE")
    else
      defconLog("INCIDENT ROUGE | " .. tostring(reason))
    end
  elseif not defconAtLeast("JAUNE") then
    setDefcon("JAUNE", reason, "AUTOMATIQUE")
  else
    defconLog("INCIDENT | " .. tostring(reason))
  end
end


local function ensureDataDirectory()
  if not filesystem.exists(DATA_DIRECTORY) then
    filesystem.makeDirectory(DATA_DIRECTORY)
  end
end

local function defaultTeamRecord(team)
  return {
    team = team,
    status = "DISPONIBLE",
    destination = "",
    address = "",
    missionType = "",
    startedAt = 0
  }
end

local function initializeTeams()
  for _, team in ipairs(SG_TEAMS) do
    if not teamState[team] then
      teamState[team] = defaultTeamRecord(team)
    end
  end
end

local function saveTeams()
  ensureDataDirectory()
  initializeTeams()

  local file, reason = io.open(TEAM_DATABASE_FILE, "w")

  if not file then
    log("ERREUR SAUVEGARDE EQUIPES : " ..
      safeToString(reason))
    return false, reason
  end

  for _, team in ipairs(SG_TEAMS) do
    local record = teamState[team]

    file:write(
      team .. "\t" ..
      safeToString(record.status) .. "\t" ..
      safeToString(record.destination) .. "\t" ..
      safeToString(record.address) .. "\t" ..
      safeToString(record.missionType) .. "\t" ..
      tostring(tonumber(record.startedAt) or 0) ..
      "\n"
    )
  end

  file:close()
  return true
end

local function loadTeams()
  initializeTeams()
  ensureDataDirectory()

  local file = io.open(TEAM_DATABASE_FILE, "r")

  if not file then
    saveTeams()
    return
  end

  for line in file:lines() do
    local team, status, destination, address,
      missionType, startedAt =
      line:match(
        "^([^\t]*)\t([^\t]*)\t([^\t]*)\t" ..
        "([^\t]*)\t([^\t]*)\t([^\t]*)$"
      )

    if team and teamState[team] then
      teamState[team] = {
        team = team,
        status = status ~= "" and status or "DISPONIBLE",
        destination = destination or "",
        address = address or "",
        missionType = missionType or "",
        startedAt = tonumber(startedAt) or 0
      }
    end
  end

  file:close()
  saveTeams()
end

local function setTeamAvailable(team)
  if not teamState[team] then
    return false
  end

  teamState[team] = defaultTeamRecord(team)
  saveTeams()
  return true
end

local function setTeamOnMission(mission)
  if not mission or not mission.team then
    return false
  end

  teamState[mission.team] = {
    team = mission.team,
    status = "EN MISSION",
    destination = mission.destination or "",
    address = mission.address or "",
    missionType = mission.missionType or "",
    startedAt = currentTimestamp()
  }

  saveTeams()

  if recordPlanetVisit then
    recordPlanetVisit(
      mission.destination or "INCONNUE",
      mission.team
    )
  end

  return true
end

local function findMissionByAddress(address)
  local wanted = normalizeAddress(address or "")

  if wanted == "" then
    return nil
  end

  for _, team in ipairs(SG_TEAMS) do
    local record = teamState[team]

    if record
       and record.status == "EN MISSION"
       and normalizeAddress(record.address or "") == wanted then
      return record
    end
  end

  return nil
end

local function availableTeams()
  local values = {}

  for _, team in ipairs(SG_TEAMS) do
    local record = teamState[team]

    if not record or record.status == "DISPONIBLE" then
      table.insert(values, team)
    end
  end

  return values
end

------------------------------------------------------------
-- AFFICHAGE
------------------------------------------------------------

local function header()
  clear()

  printColored("================================", UI_COLORS.title)
  printColored("          SGC CONTROL", UI_COLORS.title)
  print("   STARGATE COMMAND SYSTEM")
  print("--------------------------------")

  if defconLevel == "ROUGE" then
    printColored("      *** ALERTE ROUGE ***", UI_COLORS.red)
  elseif defconLevel == "NOIR" then
    printColored("      !!! ALERTE NOIRE !!!", UI_COLORS.red)
  else
    printColored("      ALERTE : " .. defconLevel, alertColor())
  end

  if currentUser then
    print(
      "OPERATEUR : " .. currentUser.name ..
      " [" .. currentUser.id .. "]"
    )
    print(
      "FONCTION  : " ..
      safeToString(
        personnelRoles[currentUser.role] and
        personnelRoles[currentUser.role].label or
        currentUser.role
      )
    )
  else
    printColored("OPERATEUR : AUCUNE SESSION", UI_COLORS.red)
  end

  printColored("================================", UI_COLORS.title)
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

siren = function(enabled)
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

normalizeAddress = function(address)
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

local function normalizeIDC(value)
  return tostring(value or ""):gsub("%s+", "")
end

local function findTeamByIDC(code)
  local wanted = normalizeIDC(code)

  for team, configuredCode in pairs(IDC_CODES) do
    if normalizeIDC(configuredCode) == wanted then
      return team
    end
  end

  return nil
end

local function initializeIDCTransport()
  if not IDC_ENABLED then
    return false, "IDC désactivé"
  end

  if component.isAvailable("tunnel") then
    idcTransport = component.tunnel
    idcTransportType = "LINKED CARD"
    log("Transport IDC détecté : Linked Card")
    return true
  end

  if component.isAvailable("modem") then
    idcTransport = component.modem
    idcTransportType = "CARTE RESEAU"

    local ok, reason = pcall(idcTransport.open, IDC_NETWORK_PORT)

    if not ok then
      log("Impossible d'ouvrir le port IDC : " ..
        safeToString(reason))
      return false, reason
    end

    log("Transport IDC détecté : carte réseau, port " ..
      tostring(IDC_NETWORK_PORT))
    return true
  end

  idcTransport = nil
  idcTransportType = nil
  log("Aucun transport IDC détecté")
  return false, "Aucune Linked Card ou carte réseau"
end

local function recordIDCIncident(message)
  idcFailureCount = idcFailureCount + 1

  missionLog(
    "INCIDENT IDC | " .. tostring(message) ..
    " | ECHECS " .. tostring(idcFailureCount)
  )

  log("INCIDENT IDC : " .. tostring(message))
  saveDefcon()

  if idcFailureCount >= 3 then
    registerSecurityIncident(
      "Trois tentatives IDC invalides : " .. tostring(message),
      "NOIR"
    )
  elseif idcFailureCount >= 2 then
    registerSecurityIncident(
      "Deux tentatives IDC invalides : " .. tostring(message),
      "ROUGE"
    )
  else
    registerSecurityIncident(
      "Tentative IDC invalide : " .. tostring(message),
      "JAUNE"
    )
  end
end

local function validateIDC(team, code, originAddress)
  local expected = IDC_CODES[team]

  if not expected then
    return false, "Aucun IDC configuré pour " .. safeToString(team)
  end

  if normalizeIDC(code) ~= normalizeIDC(expected) then
    return false, "Code incorrect pour " .. safeToString(team)
  end

  local mission = teamState[team]

  if not mission or mission.status ~= "EN MISSION" then
    return false, team .. " n'est pas enregistrée en mission"
  end

  local receivedOrigin = normalizeAddress(originAddress or "")
  local expectedOrigin = normalizeAddress(mission.address or "")

  if receivedOrigin ~= ""
     and expectedOrigin ~= ""
     and receivedOrigin ~= expectedOrigin then
    return false, "Origine incompatible avec la mission de " .. team
  end

  return true, mission
end

local function openIrisForValidatedIDC(team, mission)
  if defconLevel == "NOIR" then
    return false, "DEFCON NOIR : iris verrouillée"
  end

  if IDC_SECURITY_MODE == "VERROUILLE" then
    return false, "Mode verrouillé"
  end

  local ok, result, reason = pcall(gate.openIris)

  if not ok or result == nil then
    return false, safeToString(ok and reason or result)
  end

  waitForIrisState("Open", 10)
  emergencyAlarmStop()

  missionLog(
    "IDC VALIDE | " .. team ..
    " | " .. string.upper(mission.destination or "INCONNUE") ..
    " | IRIS OUVERTE"
  )

  log("IDC valide reçu pour " .. team .. ", iris ouverte")
  return true
end

local function idcMessageHandler(
  _, localAddress, remoteAddress, port, distance,
  protocol, team, code, originAddress
)
  if protocol ~= "SGC-IDC-1" then
    return
  end

  if idcTransportType == "CARTE RESEAU"
     and tonumber(port) ~= IDC_NETWORK_PORT then
    return
  end

  team = tostring(team or "")
  code = normalizeIDC(code)
  originAddress = normalizeAddress(originAddress or "")

  local valid, result = validateIDC(team, code, originAddress)

  latestIDC = {
    receivedAt = computer.uptime(),
    sender = remoteAddress,
    team = team,
    code = code,
    origin = originAddress,
    valid = valid,
    reason = valid and "IDC VALIDE" or tostring(result)
  }

  if not valid then
    closeIrisImmediately()
    siren(true)
    recordIDCIncident(
      safeToString(team) .. " | " ..
      safeToString(originAddress) .. " | " ..
      safeToString(result)
    )
    return
  end

  idcFailureCount = 0
  saveDefcon()

  missionLog(
    "IDC RECU | " .. team ..
    " | " .. string.upper(result.destination or "INCONNUE") ..
    " | MODE " .. IDC_SECURITY_MODE
  )

  if IDC_SECURITY_MODE == "AUTOMATIQUE" then
    local opened, reason =
      openIrisForValidatedIDC(team, result)

    latestIDC.openedAutomatically = opened
    latestIDC.openError = reason
  end
end

local function installIDCListener()
  if not IDC_ENABLED or idcListenerInstalled then
    return true
  end

  local okTransport = initializeIDCTransport()

  if not okTransport then
    return false
  end

  local ok, reason =
    event.listen("modem_message", idcMessageHandler)

  if ok then
    idcListenerInstalled = true
    return true
  end

  log("Impossible d'installer l'écoute IDC : " ..
    safeToString(reason))
  return false, reason
end

local function removeIDCListener()
  if idcListenerInstalled then
    pcall(event.ignore, "modem_message", idcMessageHandler)
    idcListenerInstalled = false
  end

  if idcTransportType == "CARTE RESEAU"
     and idcTransport
     and idcTransport.close then
    pcall(idcTransport.close, IDC_NETWORK_PORT)
  end
end

local function getIDCForMission(mission, incomingAddress)
  if not latestIDC then
    return nil
  end

  if computer.uptime() - latestIDC.receivedAt > 120 then
    return nil
  end

  if latestIDC.team ~= mission.team then
    return nil
  end

  local valid, result =
    validateIDC(
      latestIDC.team,
      latestIDC.code,
      incomingAddress
    )

  latestIDC.valid = valid
  latestIDC.reason = valid and "IDC VALIDE" or tostring(result)

  return latestIDC
end

closeIrisImmediately = function()
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

waitForIrisState = function(expected, timeoutSeconds)
  local timeout = computer.uptime() + (timeoutSeconds or 10)

  while computer.uptime() < timeout do
    if getIrisState() == expected then
      return true
    end

    os.sleep(0.20)
  end

  return false
end

local RETURN_PROTOCOLS = {
  NORMAL = {
    label = "RETOUR NORMAL",
    alert = nil,
    open = true
  },
  MEDICAL = {
    label = "URGENCE MEDICALE",
    alert = "JAUNE",
    open = true
  },
  QUARANTAINE = {
    label = "RISQUE BIOLOGIQUE / QUARANTAINE",
    alert = "ROUGE",
    open = true
  },
  DETRESSE = {
    label = "EQUIPE EN DETRESSE",
    alert = "ROUGE",
    open = true
  },
  CONTRAINTE = {
    label = "EQUIPE SOUS LA CONTRAINTE",
    alert = "NOIR",
    open = false
  }
}

local function selectReturnProtocol(team)
  header()
  print("PROTOCOLE DE RETOUR")
  separator()
  print("Equipe : " .. safeToString(team))
  print()
  print("1 - Retour normal")
  print("2 - Urgence medicale")
  print("3 - Quarantaine")
  print("4 - Detresse")
  print("5 - Sous la contrainte")
  print("0 - Annuler")
  separator()
  print()
  io.write("Protocole > ")

  local choice = io.read()
  local key = ({
    ["1"] = "NORMAL",
    ["2"] = "MEDICAL",
    ["3"] = "QUARANTAINE",
    ["4"] = "DETRESSE",
    ["5"] = "CONTRAINTE"
  })[choice]

  if choice == "0" then
    return nil
  end

  if not key then
    return nil, "Protocole inconnu"
  end

  return key, RETURN_PROTOCOLS[key]
end

local function authorizeReturnProtocol(team, mission, protocolKey)
  local protocol = RETURN_PROTOCOLS[protocolKey]

  if not protocol then
    return false, "Protocole inconnu"
  end

  missionLog(
    "PROTOCOLE RETOUR | " .. team ..
    " | " .. protocolKey ..
    " | " .. safeToString(mission.destination)
  )

  if protocol.alert then
    registerSecurityIncident(
      protocol.label .. " pour " .. team,
      protocol.alert
    )
  end

  if protocolKey == "CONTRAINTE" then
    closeIrisImmediately()
    siren(true)

    missionLog(
      "RETOUR REFUSE | " .. team ..
      " | CODE CONTRAINTE"
    )

    return false,
      "CODE DE CONTRAINTE : iris verrouillee, DEFCON NOIR"
  end

  if protocolKey == "QUARANTAINE" then
    header()
    print("PROTOCOLE QUARANTAINE")
    separator()
    print("Equipe : " .. team)
    print()
    print("L'ouverture de l'iris place la base")
    print("en confinement biologique.")
    print()
    print("Tape OUVRIR pour confirmer.")
    io.write("> ")

    if io.read() ~= "OUVRIR" then
      closeIrisImmediately()
      missionLog(
        "QUARANTAINE ANNULEE | " .. team
      )
      return false, "Ouverture annulee par l'operateur"
    end
  elseif protocolKey == "DETRESSE" then
    header()
    print("PROTOCOLE DETRESSE")
    separator()
    print("Equipe : " .. team)
    print()
    print("Ouverture d'urgence demandee.")
    print("Tape SECOURS pour confirmer.")
    io.write("> ")

    if io.read() ~= "SECOURS" then
      closeIrisImmediately()
      missionLog(
        "SECOURS NON AUTORISE | " .. team
      )
      return false, "Autorisation de secours refusee"
    end
  elseif protocolKey == "MEDICAL" then
    header()
    print("URGENCE MEDICALE")
    separator()
    print("Equipe : " .. team)
    print()
    print("Prepare l'equipe medicale.")
    print("Tape MEDICAL pour ouvrir l'iris.")
    io.write("> ")

    if io.read() ~= "MEDICAL" then
      closeIrisImmediately()
      return false, "Ouverture medicale annulee"
    end
  end

  return openIrisForValidatedIDC(team, mission)
end

local function incomingConnectionScreen()
  if not pendingIncoming then
    return
  end

  local incoming = pendingIncoming
  pendingIncoming = nil

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
  incoming.returnMission =
    findMissionByAddress(incoming.address)

  local function completeReturn(mission)
    local elapsed =
      currentTimestamp() - (mission.startedAt or 0)

    setTeamAvailable(mission.team)

    if recordPlanetReturn then
      recordPlanetReturn(
        mission.destination or "INCONNUE"
      )
    end

    missionLog(
      "RETOUR CONFIRME | " .. mission.team ..
      " | " .. string.upper(
        mission.destination or "INCONNUE"
      ) ..
      " | DUREE " .. formatDuration(elapsed)
    )

    log(
      "Retour confirmé de " .. mission.team ..
      " depuis " .. safeToString(incoming.address)
    )

    print()
    print("MISSION TERMINEE")
    print("Equipe : " .. mission.team)
    print("Duree  : " .. formatDuration(elapsed))
    waitForEnter()
  end

  while true do
    local receivedIDC = nil

    if incoming.returnMission then
      receivedIDC =
        getIDCForMission(incoming.returnMission, incoming.address)
    end

    header()
    print("********************************")

    if incoming.returnMission then
      print("      RETOUR D'EQUIPE SG")
    else
      print("    ALERTE PORTE ENTRANTE")
    end

    print("********************************")
    print()

    print("ORIGINE : " ..
      (incoming.name and string.upper(incoming.name) or "INCONNUE"))
    print("ADRESSE : " ..
      (incoming.address ~= "" and incoming.address or "NON RECUE"))

    local state, chevrons, direction = getGateState()

    print("ETAT    : " .. safeToString(state))
    print("CHEVRONS: " .. safeToString(chevrons))
    print("SENS    : " .. safeToString(direction))
    print("IRIS    : " .. safeToString(getIrisState()))
    print()

    if incoming.returnMission then
      local mission = incoming.returnMission
      local elapsed =
        currentTimestamp() - (mission.startedAt or 0)

      print("EQUIPE  : " .. mission.team)
      print("MISSION : " .. mission.missionType)
      print("DUREE   : " .. formatDuration(elapsed))
      print("MODE IDC: " .. IDC_SECURITY_MODE)
      print("RESEAU  : " ..
        safeToString(idcTransportType or "NON DETECTE"))

      if receivedIDC then
        print("IDC     : " ..
          (receivedIDC.valid and "VALIDE" or "INVALIDE"))

        if not receivedIDC.valid then
          print("DETAIL  : " .. safeToString(receivedIDC.reason))
        elseif receivedIDC.openedAutomatically then
          print("ACTION  : IRIS OUVERTE AUTOMATIQUEMENT")
        end
      else
        print("IDC     : EN ATTENTE")
      end

      print()
    end

    if incoming.irisError then
      print("ATTENTION : fermeture automatique")
      print("de l'iris non confirmée.")
      print("Detail : " .. safeToString(incoming.irisError))
      print()
    end

    if state == "Idle" or state == "Offline" then
      emergencyAlarmStop()
      print("La connexion entrante est terminée.")
      log("Fin de connexion entrante [" ..
        safeToString(incoming.address) .. "]")
      waitForEnter()
      return
    end

    separator()

    if incoming.returnMission then
      print("1 - Traiter le dernier IDC reçu")
      print("2 - Saisir un IDC manuellement")
      print("3 - Ouvrir l'iris sans IDC")
      print("4 - Maintenir l'iris fermée")
      print("5 - Signaler une anomalie")
      print("6 - Actualiser")
      print("7 - Fermer la connexion")
    else
      print("1 - Ouvrir l'iris manuellement")
      print("2 - Maintenir l'iris fermée")
      print("3 - Fermer la connexion")
      print("4 - Actualiser")
    end

    separator()
    print()
    io.write("Decision SGC > ")

    local choice = io.read()

    if incoming.returnMission and choice == "1" then
      if not receivedIDC then
        print()
        print("AUCUN IDC RECU POUR CETTE EQUIPE")
        pause(2)

      elseif not receivedIDC.valid then
        closeIrisImmediately()
        siren(true)
        print()
        print("IDC INVALIDE")
        print(safeToString(receivedIDC.reason))
        pause(2)

      elseif IDC_SECURITY_MODE == "VERROUILLE" then
        print()
        print("MODE VERROUILLE")
        print("L'iris ne peut pas être ouverte par IDC.")
        pause(2)

      else
        local protocolKey, protocolOrError =
          selectReturnProtocol(
            incoming.returnMission.team
          )

        if not protocolKey then
          print()
          print("PROTOCOLE ANNULE")
          print(safeToString(protocolOrError or ""))
          pause(1)
        else
          local opened, reason =
            authorizeReturnProtocol(
              incoming.returnMission.team,
              incoming.returnMission,
              protocolKey
            )

          if opened then
            completeReturn(incoming.returnMission)
            return
          end

          print()
          print("IRIS NON OUVERTE")
          print(safeToString(reason))
          pause(2)
        end
      end

    elseif incoming.returnMission and choice == "2" then
      print()
      io.write("IDC reçu > ")
      local manualCode = io.read()

      local valid, result =
        validateIDC(
          incoming.returnMission.team,
          manualCode,
          incoming.address
        )

      if not valid then
        closeIrisImmediately()
        siren(true)
        recordIDCIncident(
          incoming.returnMission.team ..
          " | SAISIE MANUELLE | " ..
          safeToString(result)
        )
        print()
        print("IDC INVALIDE")
        print(safeToString(result))
        pause(2)

      elseif IDC_SECURITY_MODE == "VERROUILLE" then
        missionLog(
          "IDC MANUEL VALIDE MAIS VERROUILLE | " ..
          incoming.returnMission.team
        )
        print()
        print("IDC VALIDE, MAIS MODE VERROUILLE")
        pause(2)

      else
        local protocolKey, protocolOrError =
          selectReturnProtocol(
            incoming.returnMission.team
          )

        if not protocolKey then
          print()
          print("PROTOCOLE ANNULE")
          print(safeToString(protocolOrError or ""))
          pause(1)
        else
          local opened, reason =
            authorizeReturnProtocol(
              incoming.returnMission.team,
              incoming.returnMission,
              protocolKey
            )

          if opened then
            completeReturn(incoming.returnMission)
            return
          end

          print()
          print("IRIS NON OUVERTE")
          print(safeToString(reason))
          pause(2)
        end
      end

    elseif incoming.returnMission and choice == "3" then
      local ok, result, reason = pcall(gate.openIris)

      if not ok or result == nil then
        print()
        print("ECHEC D'OUVERTURE : " ..
          safeToString(ok and reason or result))
        pause(2)
      else
        waitForIrisState("Open", 10)
        emergencyAlarmStop()

        missionLog(
          "OUVERTURE FORCEE SANS IDC | " ..
          incoming.returnMission.team ..
          " | " .. safeToString(incoming.address)
        )

        registerSecurityIncident(
          "Ouverture forcée sans IDC pour " ..
          incoming.returnMission.team,
          "ROUGE"
        )

        completeReturn(incoming.returnMission)
        return
      end

    elseif incoming.returnMission and choice == "4" then
      closeIrisImmediately()
      emergencyAlarmStop()
      log("Iris maintenue fermée pour retour de " ..
        incoming.returnMission.team)
      print()
      print("IRIS MAINTENUE FERMEE")
      pause(1)

    elseif incoming.returnMission and choice == "5" then
      closeIrisImmediately()
      siren(true)

      missionLog(
        "ANOMALIE RETOUR | " ..
        incoming.returnMission.team ..
        " | " .. safeToString(incoming.address)
      )

      print()
      print("ANOMALIE ENREGISTREE")
      print("L'iris reste fermée.")
      pause(2)

    elseif incoming.returnMission and choice == "6" then
      -- Réaffichage.

    elseif incoming.returnMission and choice == "7" then
      pcall(gate.disconnect)
      emergencyAlarmStop()
      return

    elseif not incoming.returnMission and choice == "1" then
      local ok, result, reason = pcall(gate.openIris)

      if not ok or result == nil then
        print()
        print("ECHEC D'OUVERTURE : " ..
          safeToString(ok and reason or result))
        pause(2)
      else
        waitForIrisState("Open", 10)
        emergencyAlarmStop()
        missionLog(
          "OUVERTURE MANUELLE ORIGINE NON AUTHENTIFIEE | " ..
          safeToString(incoming.address)
        )

        registerSecurityIncident(
          "Iris ouverte pour une origine non authentifiée",
          "ROUGE"
        )
      end

    elseif not incoming.returnMission and choice == "2" then
      closeIrisImmediately()
      emergencyAlarmStop()
      print()
      print("IRIS MAINTENUE FERMEE")
      pause(1)

    elseif not incoming.returnMission and choice == "3" then
      pcall(gate.disconnect)
      emergencyAlarmStop()
      return

    elseif not incoming.returnMission and choice == "4" then
      -- Réaffichage.

    else
      print()
      print("Commande inconnue.")
      pause(1)
    end
  end
end

local function sanitizeIntelField(value)
  return tostring(value or "")
    :gsub("\t", " ")
    :gsub("\r", " ")
    :gsub("\n", " ")
end

local function defaultIntelligenceRecord(name)
  return {
    name = tostring(name or "INCONNUE"),
    visits = 0,
    returns = 0,
    lastVisit = 0,
    lastReturn = 0,
    discoveredBy = "",
    status = "",
    threat = "",
    population = "",
    contact = "",
    notes = ""
  }
end

local function getIntelligenceRecord(name)
  local key = normalizeName(name)

  if not intelligenceData[key] then
    intelligenceData[key] = defaultIntelligenceRecord(name)
  end

  return intelligenceData[key]
end

local function saveIntelligence()
  if not filesystem.exists(DATA_DIRECTORY) then
    filesystem.makeDirectory(DATA_DIRECTORY)
  end

  local file = io.open(INTELLIGENCE_DATABASE_FILE, "w")

  if not file then
    log("Impossible de sauvegarder la base de renseignement")
    return false
  end

  for key, record in pairs(intelligenceData) do
    file:write(table.concat({
      sanitizeIntelField(key),
      sanitizeIntelField(record.name),
      tostring(record.visits or 0),
      tostring(record.returns or 0),
      tostring(record.lastVisit or 0),
      tostring(record.lastReturn or 0),
      sanitizeIntelField(record.discoveredBy),
      sanitizeIntelField(record.status),
      sanitizeIntelField(record.threat),
      sanitizeIntelField(record.population),
      sanitizeIntelField(record.contact),
      sanitizeIntelField(record.notes)
    }, "\t") .. "\n")
  end

  file:close()
  return true
end

local function loadIntelligence()
  intelligenceData = {}
  local file = io.open(INTELLIGENCE_DATABASE_FILE, "r")

  if not file then
    for name in pairs(ADDRESS_BOOK) do
      getIntelligenceRecord(name)
    end

    saveIntelligence()
    return
  end

  for line in file:lines() do
    local fields = {}

    for field in (line .. "\t"):gmatch("(.-)\t") do
      table.insert(fields, field)
    end

    local key = fields[1]

    if key and key ~= "" then
      intelligenceData[key] = {
        name = fields[2] or key,
        visits = tonumber(fields[3]) or 0,
        returns = tonumber(fields[4]) or 0,
        lastVisit = tonumber(fields[5]) or 0,
        lastReturn = tonumber(fields[6]) or 0,
        discoveredBy = fields[7] or "",
        status = fields[8] or "",
        threat = fields[9] or "",
        population = fields[10] or "",
        contact = fields[11] or "",
        notes = fields[12] or ""
      }
    end
  end

  file:close()

  for name in pairs(ADDRESS_BOOK) do
    getIntelligenceRecord(name)
  end
end

recordPlanetVisit = function(name, team)
  local record = getIntelligenceRecord(name)
  record.visits = (record.visits or 0) + 1
  record.lastVisit = currentTimestamp()

  if record.discoveredBy == "" and team then
    record.discoveredBy = tostring(team)
  end

  saveIntelligence()
end

recordPlanetReturn = function(name)
  local record = getIntelligenceRecord(name)
  record.returns = (record.returns or 0) + 1
  record.lastReturn = currentTimestamp()
  saveIntelligence()
end

local function formatIntelTime(value)
  value = tonumber(value) or 0

  if value <= 0 then
    return "JAMAIS"
  end

  if os.date then
    return os.date("%Y-%m-%d %H:%M", value)
  end

  return tostring(value)
end

local function editIntelligenceRecord(name)
  if not requirePermission("intelligence_edit") then
    return
  end

  local record = getIntelligenceRecord(name)

  while true do
    header()
    print("EDITION DU DOSSIER : " .. string.upper(name))
    separator()
    print("1 - Statut      : " ..
      (record.status ~= "" and record.status or "HERITE"))
    print("2 - Menace      : " ..
      (record.threat ~= "" and record.threat or "HERITEE"))
    print("3 - Population  : " ..
      (record.population ~= "" and record.population or "INCONNUE"))
    print("4 - Contact     : " ..
      (record.contact ~= "" and record.contact or "INCONNU"))
    print("5 - Notes       : " ..
      (record.notes ~= "" and record.notes or "AUCUNE"))
    print("0 - Retour")
    print()
    io.write("Champ > ")

    local choice = io.read()

    if choice == "0" then
      saveIntelligence()
      return
    end

    local field = ({
      ["1"] = "status",
      ["2"] = "threat",
      ["3"] = "population",
      ["4"] = "contact",
      ["5"] = "notes"
    })[choice]

    if field then
      print()
      io.write("Nouvelle valeur > ")
      record[field] = io.read() or ""
      saveIntelligence()
      missionLog(
        "RENSEIGNEMENT MODIFIE | " ..
        string.upper(name) .. " | " .. field
      )
    else
      print("Selection inconnue.")
      pause(1)
    end
  end
end


local function getDestinationInfo(name)
  local key = normalizeName(name)
  local data = DESTINATION_DATA[key] or {}
  local intel = getIntelligenceRecord(name)

  return {
    galaxy = data.galaxy or "INCONNUE",
    status = intel.status ~= "" and intel.status
      or data.status or "NON DETERMINE",
    threat = intel.threat ~= "" and intel.threat
      or data.threat or "INCONNU",
    notes = intel.notes ~= "" and intel.notes
      or data.notes or "Aucune note disponible.",
    population = intel.population ~= "" and intel.population
      or "INCONNUE",
    contact = intel.contact ~= "" and intel.contact
      or "INCONNU",
    visits = intel.visits or 0,
    returns = intel.returns or 0,
    lastVisit = intel.lastVisit or 0,
    lastReturn = intel.lastReturn or 0,
    discoveredBy = intel.discoveredBy ~= "" and intel.discoveredBy
      or "NON RENSEIGNE"
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

  while true do
    local info = getDestinationInfo(resolvedName)

    header()
    printColored(
      "DOSSIER DE RENSEIGNEMENT GALACTIQUE",
      UI_COLORS.cyan
    )
    separator()
    print("CODE        : " .. string.upper(resolvedName))
    print("ADRESSE     : " .. address)
    print("GALAXIE     : " .. info.galaxy)
    print("STATUT      : " .. info.status)
    print("MENACE      : " .. info.threat)
    print("POPULATION  : " .. info.population)
    print("CONTACT     : " .. info.contact)
    print()
    print("VISITES     : " .. tostring(info.visits))
    print("RETOURS     : " .. tostring(info.returns))
    print("DECOUVERTE  : " .. info.discoveredBy)
    print("DERN. DEPART: " .. formatIntelTime(info.lastVisit))
    print("DERN. RETOUR: " .. formatIntelTime(info.lastReturn))
    print()
    print("NOTES")
    separator()
    print(info.notes)
    print()
    print("1 - Modifier le dossier")
    print("0 - Retour")
    print()
    io.write("Action > ")

    local choice = io.read()

    if choice == "0" then
      return
    elseif choice == "1" then
      editIntelligenceRecord(resolvedName)
    else
      print("Commande inconnue.")
      pause(1)
    end
  end
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
  if defconAtLeast("ROUGE") then
    header()
    print("AUTORISATION DE MISSION REFUSEE")
    print()
    print("Niveau actuel : " .. defconLevel)
    print("Motif          : " .. defconReason)
    print()
    print("Reviens au niveau JAUNE ou VERT")
    print("avant d'autoriser un depart.")
    missionLog(
      "MISSION BLOQUEE | DEFCON " .. defconLevel
    )
    waitForEnter()
    return nil
  end

  local destination = selectFromList(
    "SELECTION DE LA DESTINATION",
    sortedDestinationNames()
  )

  if not destination then
    return nil
  end

  local teams = availableTeams()

  if #teams == 0 then
    header()
    print("AUCUNE EQUIPE DISPONIBLE")
    print()
    print("Toutes les equipes SG sont deja en mission.")
    waitForEnter()
    return nil
  end

  local team = selectFromList(
    "SELECTION DE L'EQUIPE",
    teams
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

  if defconLevel == "NOIR" then
    print("COMPOSITION INTERDITE")
    print()
    print("La base est en ALERTE NOIRE.")
    print("Aucune connexion sortante n'est autorisee.")
    print("Motif : " .. defconReason)
    missionLog(
      "COMPOSITION BLOQUEE | DEFCON NOIR | " ..
      safeToString(rawAddress)
    )
    waitForEnter()
    return false
  end

  if defconLevel == "ROUGE" then
    print("COMPOSITION INTERDITE")
    print()
    print("La base est en ALERTE ROUGE.")
    print("Les missions et compositions sortantes")
    print("sont suspendues.")
    print("Motif : " .. defconReason)
    missionLog(
      "COMPOSITION BLOQUEE | DEFCON ROUGE | " ..
      safeToString(rawAddress)
    )
    waitForEnter()
    return false
  end

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
      setTeamOnMission(mission)

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

local function showOperationsCenter()
  header()
  print("CENTRE DES OPERATIONS")
  separator()

  local activeCount = 0

  for _, team in ipairs(SG_TEAMS) do
    local record =
      teamState[team] or defaultTeamRecord(team)

    print(team .. " : " .. record.status)

    if record.status == "EN MISSION" then
      activeCount = activeCount + 1

      local elapsed =
        currentTimestamp() - (record.startedAt or 0)

      print("  Destination : " ..
        string.upper(record.destination or "INCONNUE"))
      print("  Mission     : " ..
        safeToString(record.missionType))
      print("  Duree       : " ..
        formatDuration(elapsed))
    end

    print()
  end

  separator()
  print("Equipes en mission : " .. tostring(activeCount))
  waitForEnter()
end

local function teamAdministration()
  while true do
    header()
    print("ADMINISTRATION DES EQUIPES")
    separator()

    for index, team in ipairs(SG_TEAMS) do
      local record = teamState[team]

      print(
        tostring(index) .. " - " .. team ..
        " [" .. safeToString(record.status) .. "]"
      )
    end

    print()
    print("0 - Retour")
    print()
    io.write("Equipe a remettre disponible > ")

    local choice = io.read()

    if choice == "0" then
      return
    end

    local index = tonumber(choice)
    local team = index and SG_TEAMS[index]

    if team then
      local record = teamState[team]

      header()
      print("CONFIRMATION")
      separator()
      print("Equipe : " .. team)
      print("Etat   : " .. safeToString(record.status))
      print()
      print("1 - Remettre DISPONIBLE")
      print("2 - Annuler")
      print()
      io.write("Decision > ")

      if io.read() == "1" then
        setTeamAvailable(team)
        missionLog(
          "REINITIALISATION MANUELLE | " .. team
        )
        print()
        print(team .. " est maintenant DISPONIBLE.")
        pause(1)
      end
    else
      print("Selection inconnue.")
      pause(1)
    end
  end
end

local function showDefconControl()
  while true do
    header()
    print("CONTROLE DES NIVEAUX D'ALERTE")
    separator()
    print("Niveau actuel : " .. defconLevel)
    print("Motif         : " .. defconReason)
    print("Echecs IDC    : " .. tostring(idcFailureCount))
    print()
    print("VERT  : fonctionnement normal")
    print("JAUNE : confirmation renforcée")
    print("ROUGE : départs et compositions interdits")
    print("NOIR  : verrouillage de la base et de l'iris")
    print()
    print("Protocoles retour : NORMAL, MEDICAL,")
    print("QUARANTAINE, DETRESSE, CONTRAINTE")
    print()
    separator()
    print("1 - Passer au niveau VERT")
    print("2 - Passer au niveau JAUNE")
    print("3 - Passer au niveau ROUGE")
    print("4 - Passer au niveau NOIR")
    print("5 - Consulter le journal DEFCON")
    print("0 - Retour")
    separator()
    print()
    io.write("Choix > ")

    local choice = io.read()

    if choice == "0" then
      return
    elseif choice == "5" then
      header()
      print("JOURNAL DEFCON")
      separator()

      local file = io.open(DEFCON_LOG_FILE, "r")

      if not file then
        print("Le journal DEFCON est vide.")
      else
        local lines = {}

        for line in file:lines() do
          table.insert(lines, line)

          if #lines > 30 then
            table.remove(lines, 1)
          end
        end

        file:close()

        for _, line in ipairs(lines) do
          print(line)
        end
      end

      waitForEnter()
    else
      local requested = ({
        ["1"] = "VERT",
        ["2"] = "JAUNE",
        ["3"] = "ROUGE",
        ["4"] = "NOIR"
      })[choice]

      if not requested then
        print("Choix inconnu.")
        pause(1)
      elseif not hasPermission("defcon_change") then
        denyPermission("defcon_change")
      elseif requested == "NOIR" and
             not hasPermission("defcon_black") then
        header()
        printColored(
          "AUTORISATION STRATEGIQUE REQUISE",
          UI_COLORS.red
        )
        separator()
        print("Le passage au DEFCON NOIR est reserve")
        print("au commandement general.")
        print()
        securityLog("ACCES REFUSE", "DEFCON NOIR")
        waitForEnter()
      else
        print()
        io.write("Motif du changement > ")
        local reason = io.read()

        if requested == "VERT" and defconLevel ~= "VERT" then
          print()
          print("Retour au VERT : tape CONFIRMER")
          io.write("> ")

          if io.read() ~= "CONFIRMER" then
            print("Changement annulé.")
            pause(1)
          else
            idcFailureCount = 0
            IDC_SECURITY_MODE = "CONFIRMATION"
            emergencyAlarmStop()
            setDefcon("VERT", reason, "OPERATEUR")
          end
        else
          setDefcon(requested, reason, "OPERATEUR")
        end
      end
    end
  end
end

local function showIDCSecurity()
  while true do
    header()
    print("SECURITE IDC")
    separator()
    print("Transmission distante : DESACTIVEE")
    print("Saisie IDC             : CONSOLE SGC")
    print("Mode      : " .. IDC_SECURITY_MODE)
    print("Incidents : " .. tostring(idcFailureCount))
    print()

    for _, team in ipairs(SG_TEAMS) do
      print(team .. " : IDC CONFIGURE")
    end

    print()
    separator()
    print("1 - Mode AUTOMATIQUE")
    print("2 - Mode CONFIRMATION")
    print("3 - Mode VERROUILLE")
    print("4 - Réinitialiser le transport")
    print("0 - Retour")
    separator()
    print()
    io.write("Choix > ")

    local choice = io.read()

    if choice == "1" then
      IDC_SECURITY_MODE = "AUTOMATIQUE"
      missionLog("MODE IDC | AUTOMATIQUE")

    elseif choice == "2" then
      IDC_SECURITY_MODE = "CONFIRMATION"
      missionLog("MODE IDC | CONFIRMATION")

    elseif choice == "3" then
      IDC_SECURITY_MODE = "VERROUILLE"
      closeIrisImmediately()
      missionLog("MODE IDC | VERROUILLE")

    elseif choice == "4" then
      removeIDCListener()
      initializeIDCTransport()
      installIDCListener()
      pause(1)

    elseif choice == "0" then
      return

    else
      print("Choix inconnu.")
      pause(1)
    end
  end
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

local function readLastEvent()
  initializeLog()
  local file = io.open(MISSION_LOG_FILE, "r")

  if not file then
    return "Aucun evenement operationnel"
  end

  local last = nil

  for line in file:lines() do
    if line ~= "" then
      last = line
    end
  end

  file:close()
  return last or "Aucun evenement operationnel"
end

local function showTacticalDashboard()
  header()

  local state, chevrons, direction = getGateState()
  local energy = getEnergy()
  local activeCount = 0

  printColored("TABLEAU TACTIQUE", UI_COLORS.cyan)
  separator()
  print(
    "SESSION    : " ..
    (currentUser and currentUser.id or "AUCUNE") ..
    " / " ..
    (currentUser and currentUser.role or "AUCUN ROLE")
  )
  print("PORTE      : " .. safeToString(state) ..
    "  | CHEVRONS : " .. safeToString(chevrons))
  print("DIRECTION  : " .. safeToString(direction))
  print("IRIS       : " .. safeToString(getIrisState()))
  print("ENERGIE    : " ..
    (energy and tostring(energy) .. " SU" or "INCONNUE"))
  print("ALARME     : " ..
    (alarmActive and "ACTIVE" or "PRETE"))
  print()

  printColored("EQUIPES SG", UI_COLORS.cyan)
  separator()

  for _, team in ipairs(SG_TEAMS) do
    local record = teamState[team] or defaultTeamRecord(team)

    if record.status == "EN MISSION" then
      activeCount = activeCount + 1
      local elapsed =
        currentTimestamp() - (record.startedAt or 0)

      printColored(
        team .. "  EN MISSION  " ..
        formatDuration(elapsed),
        UI_COLORS.yellow
      )
      print("      " ..
        string.upper(record.destination or "INCONNUE") ..
        " / " .. safeToString(record.missionType))
    else
      printColored(
        team .. "  DISPONIBLE",
        UI_COLORS.green
      )
    end
  end

  print()
  separator()
  print("Equipes deployees : " .. tostring(activeCount))
  print()
  printColored("DERNIER EVENEMENT", UI_COLORS.cyan)
  separator()

  local lastEvent = readLastEvent()

  if #lastEvent > 78 then
    lastEvent = lastEvent:sub(1, 75) .. "..."
  end

  print(lastEvent)
  print()
end

------------------------------------------------------------
-- MENU PRINCIPAL
------------------------------------------------------------

local function main()
  initializeLog()
  loadTeams()
  loadDefcon()
  loadIntelligence()
  loadPersonnel()

  findGate()
  findAlarm()

  if gate then
    installIncomingListener()
  end

  -- Au démarrage, on arrête une éventuelle alarme
  -- restée active après un ancien plantage.
  emergencyAlarmStop()

  log("Demarrage du systeme SGC - PERSONNEL + DROITS RBAC")
  securityLog("DEMARRAGE SYSTEME", "INITIALISATION")

  if not loginScreen(false) then
    return
  end

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

    showTacticalDashboard()
    separator()
    print("1 - Centre des operations")
    print("2 - Autoriser une mission SG")
    print("3 - Composition manuelle")
    print("4 - Fermer la porte")
    print("5 - Controler l'iris")
    print("6 - Centre de renseignement")
    print("7 - Carnet d'adresses")
    print("8 - Administration des equipes")
    print("9 - Journal des missions")
    print("10 - Journal technique")
    print("11 - Diagnostic complet")
    print("12 - Methodes SGCraft")
    print("13 - Arret d'urgence de l'alarme")
    print("14 - Securite IDC")
    print("15 - Niveaux d'alerte DEFCON")
    print("16 - Personnel et droits")
    print("17 - Changer d'operateur")
    print("18 - Quitter")
    separator()
    print()

    io.write("Commande SGC > ")
    local choice = io.read()

    if pendingIncoming then
      incomingConnectionScreen()

    elseif choice == "1" then
      if requirePermission("operations") then
        securityLog("CONSULTATION", "CENTRE OPERATIONS")
        showOperationsCenter()
      end

    elseif choice == "2" then
      if requirePermission("missions") then
        local mission = buildMission()

        if mission then
          securityLog(
            "MISSION AUTORISEE",
            mission.team .. " VERS " ..
            string.upper(mission.destination)
          )
          openGate(mission.destination, mission)
        end
      end

    elseif choice == "3" then
      if requirePermission("dial") then
        header()
        print("COMPOSITION MANUELLE")
        separator()
        print()
        print("Entre un nom du carnet ou une adresse.")
        print()
        io.write("Destination > ")

        local destination = io.read()
        securityLog(
          "COMPOSITION MANUELLE",
          tostring(destination)
        )
        openGate(destination)
      end

    elseif choice == "4" then
      if requirePermission("close_gate") then
        securityLog("FERMETURE PORTE", "COMMANDE")
        closeGate()
      end

    elseif choice == "5" then
      if requirePermission("iris") then
        securityLog("CONTROLE IRIS", "MENU")
        irisMenu()
      end

    elseif choice == "6" then
      if requirePermission("intelligence_view") then
        destinationDatabase()
      end

    elseif choice == "7" then
      if requirePermission("address_book") then
        showAddressBook()
      end

    elseif choice == "8" then
      if requirePermission("teams") then
        securityLog("ADMINISTRATION", "EQUIPES SG")
        teamAdministration()
      end

    elseif choice == "9" then
      if requirePermission("mission_logs") then
        showMissionLogs()
      end

    elseif choice == "10" then
      if requirePermission("technical_logs") then
        showLogs()
      end

    elseif choice == "11" then
      if requirePermission("diagnostics") then
        showStatus()
      end

    elseif choice == "12" then
      if requirePermission("sgcraft_methods") then
        showMethods()
      end

    elseif choice == "13" then
      if requirePermission("alarm_stop") then
        header()
        emergencyAlarmStop()

        print("ARRET D'URGENCE")
        print()
        print("La commande d'arret de l'alarme")
        print("a ete envoyee.")

        securityLog("ARRET ALARME", "URGENCE")
        log("Arret d'urgence de l'alarme")
        waitForEnter()
      end

    elseif choice == "14" then
      if requirePermission("idc") then
        securityLog("SECURITE IDC", "MENU")
        showIDCSecurity()
      end

    elseif choice == "15" then
      if requirePermission("defcon_view") then
        showDefconControl()
      end

    elseif choice == "16" then
      personnelMenu()

    elseif choice == "17" then
      if requirePermission("personnel_switch") then
        loginScreen(true)
      end

    elseif choice == "18" then
      if requirePermission("shutdown") then
        securityLog("ARRET SYSTEME", "DEMANDE OPERATEUR")
        saveTeams()
        saveDefcon()
        saveIntelligence()
        saveRoles()
        saveUsers()
        removeIDCListener()
        removeIncomingListener()
        emergencyAlarmStop()
        log("Arret normal du systeme SGC")

        header()
        print("Arret du systeme SGC.")
        print("Donnees sauvegardees.")
        print("Alarme securisee.")
        return
      end

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
  saveDefcon()
  saveIntelligence()
  saveRoles()
  saveUsers()
  securityLog(
    "ARRET SUR ERREUR",
    safeToString(errorMessage)
  )
  removeIDCListener()
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
