local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

-- Create RemoteEvents for client-server communication
local remoteEvents = Instance.new("Folder")
remoteEvents.Name = "AntiWSEvents"
remoteEvents.Parent = ReplicatedStorage

local friendSettingRemote = Instance.new("RemoteEvent")
friendSettingRemote.Name = "SetFriendPermission"
friendSettingRemote.Parent = remoteEvents

local AntiWSSystem = {}
AntiWSSystem.__index = AntiWSSystem

--- @class AntiWSSystem
--- Anti-W+S System for Roblox - Prevents players from following others too closely
--- @prop config table -- Configuration settings for the system
--- @prop playerStates table -- Tracks player movement states
--- @prop punishmentCooldowns table -- Prevents spam punishment
--- @prop userSettings table -- Individual player settings
--- @prop customPunishments table -- Developer-defined custom punishments
--- @prop npcs table -- Cache of NPCs in the game
--- @prop customNPCChecker function? -- Custom function to identify NPCs
--- @prop connections table -- Stores all event connections
--- @prop explosionCooldowns table -- Prevents explosion spam

--- @interface Config
--- Configuration options for the Anti-W+S System
--- @field enabled boolean -- Whether the system is active (default: true)
--- @field detectionDistance number -- How close players need to be to trigger (default: 1.5 studs)
--- @field oscillationThreshold number -- How many direction changes needed to trigger punishment (default: 5)
--- @field checkInterval number -- How often to check positions (default: 0.1 seconds)
--- @field respectFriends boolean -- Whether to ignore friends (default: true)
--- @field defaultPunishment string -- Default punishment type (default: "explode")
--- @field punishmentCooldown number -- Cooldown between punishments (default: 5 seconds)
--- @field debugMode boolean -- Whether to show debug messages (default: false)
--- @field includeNPCs boolean -- Whether to protect NPCs from W+S behavior (default: false)
--- @field npcIdentifier string -- How to identify NPCs - "folder", "tag", or "custom" (default: "folder")
--- @field npcFolderNames table -- Array of folder names containing NPCs (default: {"NPCs"})
--- @field npcTags table -- Array of CollectionService tags for NPCs (default: {"NPC"})
--- @field explosionForce number -- Force applied during fake explosion (default: 50)

-- Default configuration
local DEFAULT_CONFIG = {
	enabled = true,
	detectionDistance = 1.5,
	oscillationThreshold = 5,
	checkInterval = 0.1,
	respectFriends = true,  -- Default to respecting friends
	defaultPunishment = "explode",
	punishmentCooldown = 5,
	debugMode = false,
	includeNPCs = false,
	npcIdentifier = "folder",
	npcFolderNames = {"NPCs"},
	npcTags = {"NPC"},
	explosionForce = 50,
}

--- Creates a new Anti-W+S System instance
--- @param config Config? -- Configuration table (optional, uses defaults if not provided)
--- @return AntiWSSystem -- New system instance
function AntiWSSystem.new(config)
	local self = setmetatable({}, AntiWSSystem)

	-- Merge config with defaults
	self.config = {}
	for key, value in pairs(DEFAULT_CONFIG) do
		if config and config[key] ~= nil then
			-- Handle array configs specially
			if key == "npcFolderNames" or key == "npcTags" then
				if type(config[key]) == "table" then
					self.config[key] = config[key]
				else
					-- Convert single value to array for backward compatibility
					self.config[key] = {config[key]}
				end
			else
				self.config[key] = config[key]
			end
		else
			self.config[key] = value
		end
	end

	-- Backward compatibility for old config names
	if config then
		if config.npcFolderName and not config.npcFolderNames then
			self.config.npcFolderNames = {config.npcFolderName}
		end
		if config.npcTag and not config.npcTags then
			self.config.npcTags = {config.npcTag}
		end
	end

	-- Validate configuration
	self:validateConfig()

	-- Internal tracking
	self.playerStates = {} -- Tracks player movement states
	self.punishmentCooldowns = {} -- Prevents spam punishment
	self.userSettings = {} -- Individual player settings
	self.customPunishments = {} -- Developer-defined custom punishments
	self.npcs = {} -- Cache of NPCs in the game
	self.customNPCChecker = nil -- Custom function to identify NPCs
	self.explosionCooldowns = {} -- Prevents explosion spam

	-- Connection storage
	self.connections = {}

	self:initialize()
	return self
end

--- Validates and corrects configuration values
function AntiWSSystem:validateConfig()
	-- Validate numeric values
	self.config.detectionDistance = math.max(1, self.config.detectionDistance or 8)
	self.config.oscillationThreshold = math.max(1, self.config.oscillationThreshold or 5)
	self.config.checkInterval = math.max(0.05, self.config.checkInterval or 0.1)
	self.config.punishmentCooldown = math.max(1, self.config.punishmentCooldown or 5)
	self.config.explosionForce = math.max(1, self.config.explosionForce or 50)

	-- Validate array configs
	if type(self.config.npcFolderNames) ~= "table" then
		self.config.npcFolderNames = {"NPCs"}
	end
	if type(self.config.npcTags) ~= "table" then
		self.config.npcTags = {"NPC"}
	end
end

function AntiWSSystem:initialize()
	if self.config.debugMode then
		print("Anti-W+S System initialized with config:", self.config)
	end

	-- Set up player tracking
	self:setupPlayerTracking()

	-- Start main detection loop
	if self.config.enabled then
		self:startDetection()
	end

	-- Set up NPC tracking if enabled
	if self.config.includeNPCs then
		self:setupNPCTracking()
	end

	-- Set up friend permission handling
	self:setupFriendPermission()
end

function AntiWSSystem:setupPlayerTracking()
	-- Initialize tracking for existing players
	for _, player in pairs(Players:GetPlayers()) do
		self:initializePlayerTracking(player)
	end

	-- Handle new players
	self.connections.playerAdded = Players.PlayerAdded:Connect(function(player)
		self:initializePlayerTracking(player)
	end)

	-- Clean up when players leave
	self.connections.playerRemoving = Players.PlayerRemoving:Connect(function(player)
		self:cleanupPlayerTracking(player)
	end)
end

function AntiWSSystem:initializePlayerTracking(player)
	self.playerStates[player] = {
		movementHistory = {},
		lastPosition = nil,
		lastDirection = nil
	}
	self.punishmentCooldowns[player] = 0
	self.explosionCooldowns[player] = 0
	self.userSettings[player] = {
		allowFriendsToFollow = true  -- Default: allow friends to follow without penalty
	}
end

function AntiWSSystem:cleanupPlayerTracking(player)
	self.playerStates[player] = nil
	self.punishmentCooldowns[player] = nil
	self.explosionCooldowns[player] = nil
	self.userSettings[player] = nil
end

function AntiWSSystem:startDetection()
	if self.connections.detectionLoop then
		self.connections.detectionLoop:Disconnect()
	end

	self.connections.detectionLoop = RunService.Heartbeat:Connect(function()
		self:detectWSBehavior()
	end)
end

function AntiWSSystem:detectWSBehavior()
	local currentTime = tick()

	for _, player in pairs(Players:GetPlayers()) do
		if not player.Character or not player.Character:FindFirstChild("HumanoidRootPart") then
			continue
		end

		local state = self.playerStates[player]
		local hrp = player.Character.HumanoidRootPart
		local currentPosition = hrp.Position

		-- Initialize last position if needed
		if not state.lastPosition then
			state.lastPosition = currentPosition
			continue
		end

		-- Calculate movement vector and direction
		local movementVector = (currentPosition - state.lastPosition) * Vector3.new(1, 0, 1)
		local movementDistance = movementVector.Magnitude

		-- Only track if player is moving
		if movementDistance > 0.1 then
			local lookVector = hrp.CFrame.LookVector
			local dotProduct = movementVector.Unit:Dot(lookVector)

			-- Determine movement direction relative to facing
			local direction
			if dotProduct > 0.7 then
				direction = "forward"
			elseif dotProduct < -0.7 then
				direction = "backward"
			else
				direction = "strafe"
			end

			-- Track direction changes
			if state.lastDirection and direction ~= state.lastDirection then
				if direction == "forward" or direction == "backward" then
					table.insert(state.movementHistory, direction)

					-- Keep only recent movements
					if #state.movementHistory > self.config.oscillationThreshold * 2 then
						table.remove(state.movementHistory, 1)
					end

					if self.config.debugMode then
						print(player.Name .. " changed direction to: " .. direction)
					end
				end
			end

			state.lastDirection = direction

			-- Check if we have enough direction changes
			if #state.movementHistory >= self.config.oscillationThreshold then
				-- Analyze movement pattern for rapid back-and-forth
				local validPattern = true
				for i = #state.movementHistory, #state.movementHistory - self.config.oscillationThreshold + 1, -1 do
					local currentDir = state.movementHistory[i]
					local prevDir = state.movementHistory[i-1]

					if not prevDir then break end

					-- Check for alternating pattern
					if not ((currentDir == "forward" and prevDir == "backward") or 
						(currentDir == "backward" and prevDir == "forward")) then
						validPattern = false
						break
					end
				end

				if validPattern then
					-- Check if player is facing a potential victim
					local victim = self:raycastForVictim(player)
					if victim then
						if self.config.debugMode then
							print(player.Name .. " detected W+S pattern with victim: " .. victim.Name)
						end

						-- Check if player is on cooldown
						if currentTime - self.punishmentCooldowns[player] >= self.config.punishmentCooldown then
							self:punishPlayer(player, victim, victim.victimType)
							self.punishmentCooldowns[player] = currentTime
							-- Clear movement history after punishment
							state.movementHistory = {}
						end
					end
				end
			end
		end

		state.lastPosition = currentPosition
	end
end

function AntiWSSystem:raycastForVictim(player)
	if not player.Character then return nil end
	local hrp = player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end

	local origin = hrp.Position + Vector3.new(0, 1, 0)  -- Slightly above to avoid ground
	local lookVector = hrp.CFrame.LookVector

	-- Cast ray forward
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
	raycastParams.FilterDescendantsInstances = {player.Character}
	raycastParams.IgnoreWater = true

	local forwardRay = workspace:Raycast(origin, lookVector * self.config.detectionDistance * 2, raycastParams)
	if forwardRay and forwardRay.Instance then
		return self:getVictimFromHit(player, forwardRay.Instance)
	end

	-- Cast ray backward as well
	local backwardRay = workspace:Raycast(origin, -lookVector * self.config.detectionDistance * 2, raycastParams)
	if backwardRay and backwardRay.Instance then
		return self:getVictimFromHit(player, backwardRay.Instance)
	end

	return nil
end

function AntiWSSystem:getVictimFromHit(offender, hitPart)
	-- Find character model from hit part
	local model = hitPart:FindFirstAncestorOfClass("Model")
	if not model then return nil end

	-- Check if it's a player
	local playerVictim = Players:GetPlayerFromCharacter(model)
	if playerVictim then
		-- Check friend permissions
		if self.config.respectFriends and self:arePlayersBlocked(offender, playerVictim) then
			if self.userSettings[playerVictim].allowFriendsToFollow then
				return nil  -- Skip punishment for friends
			end
		end
		return {victim = playerVictim, victimType = "player"}
	end

	-- Check if it's an NPC
	if self.config.includeNPCs then
		if table.find(self.npcs, model) then
			return {victim = model, victimType = "npc"}
		end
	end

	return nil
end

function AntiWSSystem:arePlayersBlocked(player1, player2)
	-- Check if players are friends
	local success1, result1 = pcall(function()
		return player1:IsFriendsWith(player2.UserId)
	end)

	if success1 and result1 then
		return true
	end

	return false
end

function AntiWSSystem:punishPlayer(offender, victim, targetType)
	-- Ensure victimName is always a valid string
	local victimName = "Unknown"
	if victim then
		if targetType == "npc" then
			victimName = victim.Name or "NPC"
		else
			victimName = victim.Name or "Player"
		end
	end

	if self.config.debugMode then
		print(offender.Name .. " is W+S-ing " .. victimName .. " (" .. (targetType or "player") .. ") - Applying punishment")
	end

	-- Execute punishment
	local punishmentType = self.config.defaultPunishment

	-- Built-in punishments
	if punishmentType == "explode" then
		self:explodePlayer(offender)
	elseif punishmentType == "kick" then
		self:kickPlayer(offender)
	elseif punishmentType == "teleport" then
		self:teleportPlayer(offender)
	elseif punishmentType == "fling" then
		self:flingPlayer(offender)
		-- Custom punishment handler
	else
		-- Check if it's a registered custom punishment
		if self.customPunishments[punishmentType] then
			self.customPunishments[punishmentType](offender, victim, targetType)
			-- Fallback to default custom punishment if exists
		elseif self.customPunishments.default then
			self.customPunishments.default(offender, victim, targetType)
		else
			warn("No valid punishment found: " .. punishmentType .. ". Falling back to explode.")
			self:explodePlayer(offender)
		end
	end

	-- Fire custom punishment event for developers
	self:fireCustomEvent("onPunishment", {
		offender = offender,
		victim = victim,
		victimName = victimName,
		targetType = targetType or "player",
		punishmentType = punishmentType,
		timestamp = tick()
	})
end

-- Built-in punishment methods
--- Creates a safe explosion effect that only launches the offending player
--- @param player Player -- The player to "explode"
function AntiWSSystem:explodePlayer(player)
	local currentTime = tick()

	-- Check explosion cooldown
	if currentTime - self.explosionCooldowns[player] < 10 then
		if self.config.debugMode then
			print("Skipping explosion for " .. player.Name .. " due to cooldown")
		end
		return
	end

	-- Set explosion cooldown
	self.explosionCooldowns[player] = currentTime

	-- Validate character
	if not player.Character then return end
	local character = player.Character
	if not character:FindFirstChild("HumanoidRootPart") then return end
	local humanoidRootPart = character.HumanoidRootPart

	-- Skip if already exploding
	if character:FindFirstChild("ExplosionCooldown") then return end

	-- Add cooldown tag to character
	local cooldownTag = Instance.new("BoolValue")
	cooldownTag.Name = "ExplosionCooldown"
	cooldownTag.Parent = character
	game.Debris:AddItem(cooldownTag, 10)  -- Remove after 10 seconds

	local humanoid = character:FindFirstChildOfClass("Humanoid")

	-- Create explosion sound
	local sound = Instance.new("Sound")
	sound.Name = "Explosion"
	sound.SoundId = "rbxassetid://12221984"
	sound.Volume = 1.5
	sound.Parent = humanoidRootPart

	-- Create visual explosion effect (no damage)
	local explosion = Instance.new("Explosion")
	explosion.Name = player.Name .. "_explosion"
	explosion.Position = humanoidRootPart.Position
	explosion.BlastRadius = 0
	explosion.BlastPressure = 0 -- No damage to parts
	explosion.DestroyJointRadiusPercent = 0 -- Don't destroy joints
	explosion.Parent = workspace
	game:GetService("Debris"):AddItem(explosion, 2)

	sound:Play()
	game.Debris:AddItem(sound, sound.TimeLength)

	-- Manually launch the player
	local bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(4000, 4000, 4000)

	-- Calculate launch direction (upward and slightly random)
	local launchDirection = Vector3.new(
		math.random(-10, 10),
		50, -- Upward force
		math.random(-10, 10)
	).Unit * self.config.explosionForce

	bodyVelocity.Velocity = launchDirection
	bodyVelocity.Parent = humanoidRootPart

	-- Kill the player after a brief delay
	task.delay(0.1, function()
		if character and character.Parent and humanoid then
			humanoid.Health = 0
		end
	end)

	-- Clean up BodyVelocity after launch
	task.spawn(function()
		task.wait(1)
		if bodyVelocity and bodyVelocity.Parent then
			bodyVelocity:Destroy()
		end
	end)
end

--- Kicks the offending player from the game
--- @param player Player -- The player to kick
function AntiWSSystem:kickPlayer(player)
	player:Kick("You were kicked for W+S behavior (following other players too closely)")
end

--- Teleports the offending player to a random location
--- @param player Player -- The player to teleport
function AntiWSSystem:teleportPlayer(player)
	if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
		-- Teleport to a random position (you can customize this)
		local randomPosition = Vector3.new(
			math.random(-100, 100),
			50,
			math.random(-100, 100)
		)
		player.Character.HumanoidRootPart.Position = randomPosition
	end
end

--- Flings the offending player
--- @param player Player -- The player to fling
function AntiWSSystem:flingPlayer(player)
	if player.Character and player.Character:FindFirstChild("Humanoid") then

		local Humanoid = player.Character:FindFirstChildOfClass("Humanoid")

		Humanoid.PlatformStand = true

		local HRP = player.Character.HumanoidRootPart

		local flingDirection = (HRP.Position - HRP.Position).Unit

		local velocity = Instance.new("BodyVelocity")
		velocity.Velocity = flingDirection * 10
		velocity.MaxForce = Vector3.new(999999, 999999, 999999)
		velocity.Parent = HRP

		local sound = Instance.new("Sound")
		sound.SoundId = "rbxassetid://129432532096499"
		sound.Parent = HRP
		sound:Play()

		-- Remove the velocity object after a short delay to stop the fling
		game.Debris:AddItem(velocity, 0.5)

		-- Reset platform stand after a delay
		task.delay(3, function()
			if Humanoid and Humanoid.Parent then
				Humanoid.PlatformStand = false
			end
		end)
	end
end

-- NPC Management Methods

--- Set up NPC tracking based on the configured identifier method
function AntiWSSystem:setupNPCTracking()
	if self.config.npcIdentifier == "folder" then
		self:setupFolderNPCTracking()
	elseif self.config.npcIdentifier == "tag" then
		self:setupTagNPCTracking()
	elseif self.config.npcIdentifier == "custom" then
		self:setupCustomNPCTracking()
	end

	if self.config.debugMode then
		print("NPC tracking set up using method: " .. self.config.npcIdentifier)
	end
end

--- Track NPCs from multiple specified folders in workspace
function AntiWSSystem:setupFolderNPCTracking()
	for _, folderName in pairs(self.config.npcFolderNames) do
		local npcFolder = workspace:FindFirstChild(folderName)

		if npcFolder then
			-- Add existing NPCs
			for _, npc in pairs(npcFolder:GetChildren()) do
				if npc:IsA("Model") and npc:FindFirstChild("HumanoidRootPart") then
					self:addNPC(npc)
				end
			end

			-- Track new NPCs added to folder
			local addedConnection = npcFolder.ChildAdded:Connect(function(child)
				if child:IsA("Model") and child:FindFirstChild("HumanoidRootPart") then
					self:addNPC(child)
				end
			end)
			table.insert(self.connections, addedConnection)

			-- Track NPCs removed from folder
			local removedConnection = npcFolder.ChildRemoved:Connect(function(child)
				self:removeNPC(child)
			end)
			table.insert(self.connections, removedConnection)

			if self.config.debugMode then
				print("Set up NPC tracking for folder: " .. folderName)
			end
		else
			warn("NPC folder '" .. folderName .. "' not found in workspace")
		end
	end
end

--- Track NPCs using multiple CollectionService tags
function AntiWSSystem:setupTagNPCTracking()
	for _, tag in pairs(self.config.npcTags) do
		-- Add existing tagged NPCs
		for _, npc in pairs(CollectionService:GetTagged(tag)) do
			if npc:IsA("Model") and npc:FindFirstChild("HumanoidRootPart") then
				self:addNPC(npc)
			end
		end

		-- Track newly tagged NPCs
		local tagAddedConnection = CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
			if instance:IsA("Model") and instance:FindFirstChild("HumanoidRootPart") then
				self:addNPC(instance)
			end
		end)
		table.insert(self.connections, tagAddedConnection)

		-- Track untagged NPCs
		local tagRemovedConnection = CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
			self:removeNPC(instance)
		end)
		table.insert(self.connections, tagRemovedConnection)

		if self.config.debugMode then
			print("Set up NPC tracking for tag: " .. tag)
		end
	end
end

--- Set up custom NPC tracking using developer-provided function
function AntiWSSystem:setupCustomNPCTracking()
	if self.customNPCChecker then
		-- Scan workspace for NPCs using custom checker
		self:scanForCustomNPCs()

		-- Set up periodic rescanning (you might want to optimize this)
		local scanConnection = RunService.Heartbeat:Connect(function()
			if tick() % 5 < 0.1 then -- Check every 5 seconds
				self:scanForCustomNPCs()
			end
		end)
		table.insert(self.connections, scanConnection)
	else
		warn("Custom NPC identifier selected but no custom checker function provided. Use setCustomNPCChecker()")
	end
end

--- Scan workspace for NPCs using custom checker function
function AntiWSSystem:scanForCustomNPCs()
	if not self.customNPCChecker then return end

	-- Clear existing NPCs tracked by custom method
	for i = #self.npcs, 1, -1 do
		local npc = self.npcs[i]
		if npc and npc.Parent and not self.customNPCChecker(npc) then
			table.remove(self.npcs, i)
		end
	end

	-- Find new NPCs
	for _, obj in pairs(workspace:GetDescendants()) do
		if obj:IsA("Model") and obj:FindFirstChild("HumanoidRootPart") and self.customNPCChecker(obj) then
			if not table.find(self.npcs, obj) then
				self:addNPC(obj)
			end
		end
	end
end

--- Add an NPC to tracking system
--- @param npc Model -- The NPC model to add
function AntiWSSystem:addNPC(npc)
	if not table.find(self.npcs, npc) then
		table.insert(self.npcs, npc)

		if self.config.debugMode then
			print("Added NPC to tracking: " .. npc.Name)
		end

		-- Clean up when NPC is removed
		local connection
		connection = npc.AncestryChanged:Connect(function()
			if not npc.Parent then
				self:removeNPC(npc)
				connection:Disconnect()
			end
		end)
		table.insert(self.connections, connection)
	end
end

--- Remove an NPC from tracking system
--- @param npc Model -- The NPC model to remove
function AntiWSSystem:removeNPC(npc)
	local index = table.find(self.npcs, npc)
	if index then
		table.remove(self.npcs, index)

		if self.config.debugMode then
			print("Removed NPC from tracking: " .. npc.Name)
		end

		-- Clean up any tracking data for this NPC
		for _, playerTracking in pairs(self.playerStates) do
			-- We don't track NPCs in player states anymore
		end
	end
end

--- Set a custom function to identify NPCs
--- @param checkerFunction function -- Function that takes a model and returns boolean
--- 
--- Example:
--- ```lua
--- antiWS:setCustomNPCChecker(function(model)
---     return model:GetAttribute("IsNPC") == true
--- end)
--- ```
function AntiWSSystem:setCustomNPCChecker(checkerFunction)
	if type(checkerFunction) == "function" then
		self.customNPCChecker = checkerFunction

		if self.config.includeNPCs and self.config.npcIdentifier == "custom" then
			self:setupCustomNPCTracking()
		end

		if self.config.debugMode then
			print("Custom NPC checker function set")
		end
	else
		warn("NPC checker must be a function")
	end
end

--- Manually add an NPC to the tracking system
--- @param npc Model -- The NPC model to add
--- 
--- Example:
--- ```lua
--- antiWS:addManualNPC(workspace.NPCs.MyNPC)
--- ```
function AntiWSSystem:addManualNPC(npc)
	if npc and npc:IsA("Model") and npc:FindFirstChild("HumanoidRootPart") then
		self:addNPC(npc)
	else
		warn("Invalid NPC model provided to addManualNPC")
	end
end

--- Get list of currently tracked NPCs
--- @return {Model} -- Array of NPC models
function AntiWSSystem:getTrackedNPCs()
	return self.npcs
end

--- Enable/disable NPC protection
--- @param enabled boolean -- Whether to enable NPC protection
--- 
--- Example:
--- ```lua
--- antiWS:setNPCProtection(true)
--- ```
function AntiWSSystem:setNPCProtection(enabled)
	local wasEnabled = self.config.includeNPCs
	self.config.includeNPCs = enabled

	if enabled and not wasEnabled then
		self:setupNPCTracking()
	elseif not enabled and wasEnabled then
		-- Clean up NPC tracking
		self.npcs = {}
		-- Connections are cleaned up in the connections table
	end

	if self.config.debugMode then
		print("NPC protection " .. (enabled and "enabled" or "disabled"))
	end
end

--- Add a new folder to track for NPCs
--- @param folderName string -- Name of the folder to track
function AntiWSSystem:addNPCFolder(folderName)
	if not table.find(self.config.npcFolderNames, folderName) then
		table.insert(self.config.npcFolderNames, folderName)

		-- If NPC tracking is active and using folders, set up tracking for new folder
		if self.config.includeNPCs and self.config.npcIdentifier == "folder" then
			local npcFolder = workspace:FindFirstChild(folderName)
			if npcFolder then
				-- Add existing NPCs
				for _, npc in pairs(npcFolder:GetChildren()) do
					if npc:IsA("Model") and npc:FindFirstChild("HumanoidRootPart") then
						self:addNPC(npc)
					end
				end

				-- Track new NPCs
				local addedConnection = npcFolder.ChildAdded:Connect(function(child)
					if child:IsA("Model") and child:FindFirstChild("HumanoidRootPart") then
						self:addNPC(child)
					end
				end)
				table.insert(self.connections, addedConnection)

				-- Track removed NPCs
				local removedConnection = npcFolder.ChildRemoved:Connect(function(child)
					self:removeNPC(child)
				end)
				table.insert(self.connections, removedConnection)
			end
		end
	end
end

--- Friend permission functionality
function AntiWSSystem:setupFriendPermission()
	-- Friend permission toggle
	friendSettingRemote.OnServerEvent:Connect(function(player, allowFriends)
		if self.userSettings[player] then
			self.userSettings[player].allowFriendsToFollow = allowFriends

			if self.config.debugMode then
				print(player.Name .. " set friend permission: " .. tostring(allowFriends))
			end
		end
	end)
end

--- Set friend permission for a player
--- @param player Player -- Player to configure
--- @param allowFriends boolean -- Whether to allow friends to follow without penalty
function AntiWSSystem:setFriendPermission(player, allowFriends)
	if self.userSettings[player] then
		self.userSettings[player].allowFriendsToFollow = allowFriends
	end
end

--- Add a custom punishment function
--- @param name string -- Name of the punishment
--- @param punishmentFunction function -- Function to execute punishment
--- 
--- Example:
--- ```lua
--- antiWS:addCustomPunishment("money", function(offender, victim, targetType)
---     -- Remove money from offender
---     if targetType == "npc" then
---         -- Different punishment for NPCs
---         offender.leaderstats.Money.Value = offender.leaderstats.Money.Value - 200
---     else
---         offender.leaderstats.Money.Value = offender.leaderstats.Money.Value - 100
---     end
--- end)
--- ```
function AntiWSSystem:addCustomPunishment(name, punishmentFunction)
	if type(punishmentFunction) == "function" then
		self.customPunishments[name] = punishmentFunction
		if self.config.debugMode then
			print("Added custom punishment: " .. name)
		end
	else
		warn("Custom punishment must be a function")
	end
end

--- Set the default custom punishment
--- @param punishmentFunction function -- Function to execute as default custom punishment
--- 
--- Example:
--- ```lua
--- antiWS:setDefaultCustomPunishment(function(offender, victim, targetType)
---     -- Your custom logic here
---     -- targetType will be "player" or "npc"
--- end)
--- ```
function AntiWSSystem:setDefaultCustomPunishment(punishmentFunction)
	self:addCustomPunishment("default", punishmentFunction)
end

--- Change punishment type at runtime
--- @param punishmentType string -- New punishment type to use
--- 
--- Example:
--- ```lua
--- antiWS:setPunishmentType("kick")
--- ```
function AntiWSSystem:setPunishmentType(punishmentType)
	self.config.defaultPunishment = punishmentType
	if self.config.debugMode then
		print("Punishment type changed to: " .. punishmentType)
	end
end

--- Update configuration at runtime
--- @param newConfig table -- Key-value pairs to update in config
--- 
--- Example:
--- ```lua
--- antiWS:updateConfig({detectionDistance = 10, oscillationThreshold = 7})
--- ```
function AntiWSSystem:updateConfig(newConfig)
	for key, value in pairs(newConfig) do
		if self.config[key] ~= nil then
			self.config[key] = value
		end
	end
	self:validateConfig()

	if self.config.debugMode then
		print("Configuration updated:", newConfig)
	end
end

--- Enable/disable the system
--- @param enabled boolean -- Whether to enable the system
--- 
--- Example:
--- ```lua
--- antiWS:setEnabled(false)
--- ```
function AntiWSSystem:setEnabled(enabled)
	self.config.enabled = enabled

	if enabled then
		self:startDetection()
	else
		if self.connections.detectionLoop then
			self.connections.detectionLoop:Disconnect()
			self.connections.detectionLoop = nil
		end
	end
end

-- Event system for developers
function AntiWSSystem:fireCustomEvent(eventName, data)
	-- Developers can connect to these events
	if self.customEvents and self.customEvents[eventName] then
		for _, callback in pairs(self.customEvents[eventName]) do
			callback(data)
		end
	end
end

--- Connect to system events
--- @param eventName string -- Event name to connect to
--- @param callback function -- Callback function
--- 
--- Example:
--- ```lua
--- antiWS:connectEvent("onPunishment", function(data)
---     print(data.offender.Name .. " was punished for following " .. data.victim.Name)
--- end)
--- ```
function AntiWSSystem:connectEvent(eventName, callback)
	if not self.customEvents then
		self.customEvents = {}
	end

	if not self.customEvents[eventName] then
		self.customEvents[eventName] = {}
	end

	table.insert(self.customEvents[eventName], callback)
end

--- Cleanup method
function AntiWSSystem:destroy()
	for _, connection in pairs(self.connections) do
		connection:Disconnect()
	end

	self.connections = {}
	self.playerStates = {}
	self.punishmentCooldowns = {}
	self.userSettings = {}
	self.customPunishments = {}
	self.npcs = {}
	self.customNPCChecker = nil
	self.explosionCooldowns = nil

	if self.config.debugMode then
		print("Anti-W+S System destroyed")
	end
end

return AntiWSSystem
