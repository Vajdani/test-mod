Line_grav = class()
local up = sm.vec3.new(0,0,1)
function Line_grav:init( thickness, colour )
    self.effect = sm.effect.createEffect("ShapeRenderable")
	self.effect:setParameter("uuid", sm.uuid.new("628b2d61-5ceb-43e9-8334-a4135566df7a"))
    self.effect:setParameter("color", colour)
    self.effect:setScale( sm.vec3.one() * thickness )

    self.thickness = thickness
	self.spinTime = 0
	self.colour = sm.color.new(0,0,0)
end

---@param startPos Vec3
---@param endPos Vec3
---@param dt number
---@param spinSpeed number
function Line_grav:update( startPos, endPos, dt, spinSpeed )
	local delta = endPos - startPos
    local length = delta:length()

    if length < 0.0001 then
        sm.log.warning("Line_grav:update() | Length of 'endPos - startPos' must be longer than 0.")
        return
	end

	self.dt_sum = (self.dt_sum or 0) + dt
	self.colour = sm.color.new(
		math.abs( math.cos(self.dt_sum) ),
		math.abs( math.sin(self.dt_sum) ),
		math.abs( math.sin(self.dt_sum + 0.5) )
	)
	self.effect:setParameter("color", self.colour)

	local rot = sm.vec3.getRotation(up, delta)
	local speed = spinSpeed or 1
	self.spinTime = self.spinTime + dt * speed
	rot = rot * sm.quat.angleAxis( math.rad(self.spinTime), up )

	local distance = sm.vec3.new(self.thickness, self.thickness, length)

	self.effect:setPosition(startPos + delta * 0.5)
	self.effect:setScale(distance)
	self.effect:setRotation(rot)

    if not self.effect:isPlaying() then
        self.effect:start()
    end
end


dofile( "$GAME_DATA/Scripts/game/AnimationUtil.lua" )
dofile( "$SURVIVAL_DATA/Scripts/util.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/survival_constants.lua" )

---@class Grav : ToolClass
---@field line table
---@field gui GuiInterface
---@field fpAnimations table
---@field tpAnimations table
---@field deleteEffects table
---@field normalFireMode table
---@field aimBlendSpeed number
---@field blendTime number
---@field isLocal boolean
---@field copyTarget Body|Character
---@field copyTargetGui GuiInterface
Grav = class()

Grav.raycastRange = 1000 --meters
Grav.minHover = 1 --meters
Grav.maxHover = 50
Grav.lineColour = sm.color.new(0,1,1)
Grav.modes = {
	["Gravity Gun"] = {
		onEquipped = "cl_mode_grav_onEquipped"
	},
	["Tumbler"] = {
		onPrimary = "cl_mode_tumble"
	},
	["Copy/Paste Object"] = {
		onPrimary = "cl_mode_copyrightInfringement",
		onSecondary = "cl_mode_copyrightInfringement_reset"
	},
	["Delete Object"] = {
		onPrimary = "cl_mode_delete"
	},
	["Teleport"] = {
		onPrimary = "cl_mode_teleport"
	},
	["Block Replacer"] = {
		onPrimary = "cl_mode_blockReplace"
	},
}
Grav.dropDown = {
	"Gravity Gun",
	"Tumbler",
	"Copy/Paste Object",
	"Delete Object",
	"Teleport",
	"Block Replacer"
}

local camAdjust = sm.vec3.new(0,0,0.575)
local shapesInG = {}
for k, v in pairs(_G) do
	if type(v) == "Uuid" and sm.item.isBlock(v) then
		shapesInG[sm.shape.getShapeTitle(v)] = v
	end
end

local renderables = {
    "$CONTENT_DATA/Objects/mongiconnect.rend"
}

local renderablesTp = {
    "$GAME_DATA/Character/Char_Male/Animations/char_male_tp_connecttool.rend",
    "$GAME_DATA/Character/Char_Tools/Char_connecttool/char_connecttool_tp_animlist.rend"
}
local renderablesFp = {
    "$GAME_DATA/Character/Char_Tools/Char_connecttool/char_connecttool_fp_animlist.rend"
}

sm.tool.preloadRenderables( renderables )
sm.tool.preloadRenderables( renderablesTp )
sm.tool.preloadRenderables( renderablesFp )


function Grav:server_onCreate()
	self.sv = {}
	self.sv.target = nil
	self.sv.equipped = false

	self.sv.hoverRange = 5

	self.sv.copyTarget = nil

	self.sv.rotState = false
	self.sv.rotDirection = nil
	self.sv.mouseDelta = { x = 0, y = 0 }
end

function Grav:server_onDestroy()
	DEFAULT_TUMBLE_TICK_TIME = 40
end

function Grav:sv_targetSelect( target )
	self.sv.target = target
	self.network:sendToClients( "cl_targetSelect", target )
end

function Grav:sv_updateRange( range )
	self.sv.hoverRange = range
end

function Grav:sv_updateEquipped( toggle )
	self.sv.equipped = toggle
	self:sv_setRotState({state = false})
end

function Grav:sv_setRotState( args )
	self.sv.rotState = args.state
	self.sv.rotDirection = args.dir
	self.sv.mouseDelta = { x = 0, y = 0 }
end

function Grav:sv_syncMouseDelta( mouseDelta )
	self.sv.mouseDelta.x = self.sv.mouseDelta.x + mouseDelta[1]
	self.sv.mouseDelta.y = self.sv.mouseDelta.y + mouseDelta[2]
end

function Grav:server_onFixedUpdate()
	local target = self.sv.target
	local sv = self.sv
	if not target or not sm.exists(target) or not sv.equipped then return end

	--thanks 00Fant for the math
	---@type Character
	local char = self.tool:getOwner().character
	local dir = sv.rotState and sv.rotDirection or char.direction
	local pos = char.worldPosition + camAdjust + dir * sv.hoverRange

	local targetIsChar = type(target) == "Character"
	local force = pos - (targetIsChar and target.worldPosition or target:getCenterOfMassPosition())
	local mass = target.mass
	force = ((force  * 2) - ( target.velocity * 0.3 )) * mass

	if targetIsChar and target:isTumbling() then
		target:applyTumblingImpulse( force )
	else
		sm.physics.applyImpulse( target, force, true )

		if sv.rotState and not targetIsChar then
			local mouseDelta = sv.mouseDelta
			local charDir = sv.rotDirection:rotate(math.rad(mouseDelta.x), up)
			charDir = charDir:rotate(math.rad(mouseDelta.y), calculateRightVector(charDir))
			local difference = (target.worldRotation * sm.vec3.new(1,0,0)):cross(charDir)
			sm.physics.applyTorque(target, ((difference * 2) - ( target.angularVelocity * 0.3 )) * mass, true)
		end
	end
end

function calculateRightVector(vector)
    local yaw = math.atan2(vector.y, vector.x) - math.pi / 2
    return sm.vec3.new(math.cos(yaw), math.sin(yaw), 0)
end

function Grav:sv_yeet()
	local force = self.tool:getOwner().character.direction * 100 * self.sv.target.mass

	if type(self.sv.target) == "Character" and self.sv.target:isTumbling() then
		self.sv.target:applyTumblingImpulse( force )
	else
		sm.physics.applyImpulse( self.sv.target, force, true )
	end
	self:sv_targetSelect( nil )

	self:sv_setRotState({state = false})
end

function Grav:sv_targetTumble( target )
	target:setTumbling( true )
end

function Grav:sv_modifyTumbleDurationGlobal( num )
	DEFAULT_TUMBLE_TICK_TIME = num * 40
end

function Grav:sv_pasteTarget( pos )
	local target
	if type(pos) == "table" then
		target = pos.data
		pos = pos.pos
	else
		target = self.sv.copyTarget
	end

	if type(target) == "string" then
		sm.creation.importFromString(
			self.tool:getOwner().character:getWorld(),
			target,
			pos,
			sm.quat.identity(),
			true
		)
	else
		sm.unit.createUnit(target, pos)
	end
end

function Grav:sv_setCopyTarget( target )
	if type(target) == "Body" then
		self.sv.copyTarget = sm.creation.exportToString( target, false, true )
	else
		self.sv.copyTarget = target
	end
end

function Grav:sv_deleteObject( obj )
	local override, data, pos = false, nil, nil
	if type(obj) == "table" then
		override = obj.override
		pos = obj.pos
		obj = obj.obj
		data = type(obj) == "Body" and sm.creation.exportToString( obj, false, true ) or obj:getCharacterType()
	end

	if type(obj) == "Body" then
		if not override then
			self.network:sendToClients("cl_deleteObject", obj)
		end

		for k, shape in pairs(obj:getCreationShapes()) do
			if sm.item.isBlock(shape.uuid) then
				shape:destroyShape()
			else
				shape:destroyPart()
			end
		end
	else
		obj:getUnit():destroy()
	end

	if override then
		self:sv_pasteTarget( { pos = pos, data = data  } )
	end
end

function Grav:sv_replaceBlocks( args )
	---@type Body
	local body = args.body
	local new, old = tostring(args.new), tostring(args.old)
	if new == old then return end
	--[[
	local replaceID = tostring(blk_bricks)
	local newId = tostring(blk_wood1)
	local creation = sm.creation.exportToString(body, false, true)
	creation = creation:gsub(replaceID, newId)

	sm.creation.importFromString(
		body:getWorld(),
		creation,
		body.worldPosition + sm.vec3.new(0,0,10),
		sm.quat.identity()
	)
	]]

	local creation = sm.creation.exportToTable( body, false, true )
	for k, v in pairs(creation.bodies) do
		for i, j in pairs(v.childs) do
			if j.shapeId == old then
				j.shapeId = new
			end
		end
	end

	local world = body:getWorld()
	local pos = body.worldPosition
	for k, v in pairs(body:getCreationShapes()) do
		v:destroyShape()
	end

	sm.json.save(creation, "$CONTENT_DATA/exportedBP.json")
	sm.creation.importFromFile(
		world,
		"$CONTENT_DATA/exportedBP.json",
		pos + sm.vec3.new(0,0,10)
	)
end



function Grav.client_onCreate( self )
	self.isLocal = self.tool:isLocal()
	self.target = nil
	self.line = Line_grav()
	self.line:init( 0.05, self.lineColour )
	self.deleteEffects = {}

	self:loadAnimations()

    if not self.isLocal then return end
	self.hoverRange = 5
	self.canTriggerFb = true
	self.mode = "Gravity Gun"
	self.tumbleDuration = 40

	self.gui = sm.gui.createGuiFromLayout("$CONTENT_DATA/Gui/gravgun.layout", false,
		{
			isHud = false,
			isInteractive = true,
			needsCursor = true,
			hidesHotbar = false,
			isOverlapped = false,
			backgroundAlpha = 0,
		}
	)
	self.gui:createDropDown( "mode_dropdown", "cl_gui_modeDropDown", self.dropDown )
	self.gui:setTextAcceptedCallback( "tumble_duration", "cl_gui_tumbleDuration" )

	local options = {}
	for k, v in pairs(shapesInG) do
		options[#options+1] = k
	end
	self.oldUuid = blk_wood1
	self.newUuid = blk_concrete1
	--[[
	self.gui:createDropDown( "uuidOld", "cl_gui_oldUuid", options )
	self.gui:createDropDown( "uuidNew", "cl_gui_newUuid", options )
	self.gui:setSelectedDropDownItem( "uuidOld", sm.shape.getShapeTitle(self.oldUuid) )
	self.gui:setSelectedDropDownItem( "uuidNew", sm.shape.getShapeTitle(self.newUuid) )
	self.gui:setVisible( "uuidOld", false )
	self.gui:setVisible( "uuidNew", false )
	--self.gui:setMeshPreview( "meshOld", self.oldUuid )
	--self.gui:setMeshPreview( "meshNew", self.newUuid )
	]]

	self.copyTarget = nil
	self.copyTargetBodies = nil
	self.copyTargetGui = sm.gui.createWorldIconGui( 50, 50 )
    self.copyTargetGui:setImage( "Icon", "$CONTENT_DATA/Gui/aimbot_marker.png" )

	self.teleportObject = nil

	self.blockF = false
end

function Grav:client_onDestroy()
	self.line.effect:stop()
end

function Grav:cl_gui_modeDropDown( selected )
	self.mode = selected

	local visible = selected == "Block Replacer"
	self.gui:setVisible( "uuidOld", visible )
	self.gui:setVisible( "uuidNew", visible )
end

function Grav:cl_gui_tumbleDuration( widget, text )
	local num = tonumber(text)
	if num == nil then
		sm.gui.displayAlertText("#ff0000Please only enter numbers!", 2.5)
		sm.audio.play("RaftShark")
		self.gui:setText( "tumble_duration", tostring(self.tumbleDuration/40) )

		return
	end

	self.tumbleDuration = num
	self.network:sendToServer("sv_modifyTumbleDurationGlobal", self.tumbleDuration)
end

function Grav:cl_gui_oldUuid( selected )
	self.oldUuid = shapesInG[selected]
end

function Grav:cl_gui_newUuid( selected )
	self.newUuid = shapesInG[selected]
end

function Grav:cl_mode_grav_onEquipped( lmb, rmb, f )
	if self.target then
		if rmb == 1 then
			self.blockF = true
			sm.camera.setCameraState(0)
			self.network:sendToServer("sv_yeet")
			sm.gui.displayAlertText("#00ff00Target thrown!", 2.5)
			sm.audio.play("Blueprint - Build")
			return true
		end

		if lmb == 1 then
			self.blockF = true
			self.target = nil
			self.network:sendToServer( "sv_targetSelect", nil )
			sm.gui.displayAlertText("Target cleared!", 2.5)
			sm.audio.play("Blueprint - Delete")

			sm.camera.setCameraState(0)
			self.network:sendToServer("sv_setRotState", {state = false})
			return true
		end
	end

	if self.target then
		local canRotate = type(self.target) == "Body"
		if f then
			sm.gui.setInteractionText(
				sm.gui.getKeyBinding("Create", true).."Drop target\t",
				sm.gui.getKeyBinding("Attack", true).."Throw target",
				""
			)
			if canRotate then
				sm.gui.setInteractionText("<p textShadow='false' bg='gui_keybinds_bg' color='#ffffff' spacing='9'>Move your mouse to rotate the creation</p>")
			end
		else
			sm.gui.setInteractionText(
				sm.gui.getKeyBinding("Create", true).."Drop target\t",
				sm.gui.getKeyBinding("Attack", true).."Throw target",
				""
			)
			sm.gui.setInteractionText(
				sm.gui.getKeyBinding("NextCreateRotation", true).."Decrease distance\t",
				sm.gui.getKeyBinding("Reload", true).."Increase distance\t",
				canRotate and sm.gui.getKeyBinding("ForceBuild", true).."Hold to Rotate Target" or "",
				""
			)
		end

		--[[
		if self.locked == true then
			sm.localPlayer.setDirection(self.dir)
			sm.localPlayer.setLockedControls(false)
			self.locked = false
			self.dir = nil
		end
		]]

		if canRotate then
			local cam = sm.camera
			if f then
				if cam.getCameraState() ~= 2 then
					cam.setCameraState(2)
					cam.setFov(cam.getDefaultFov())
					self.dir = sm.localPlayer.getDirection()
					self.pos = cam.getDefaultPosition()
					self.network:sendToServer("sv_setRotState", {state = true, dir = self.dir})
				end

				cam.setPosition(self.pos)
				cam.setDirection(self.dir)
			elseif self.dir ~= nil then
				cam.setCameraState(0)
				self.network:sendToServer("sv_setRotState", {state = false})

				self.dir = nil
				self.pos = nil
				--[[
				if self.dir then
					sm.localPlayer.setLockedControls(true)
					self.locked = true
				end
				]]
			end
		end

		return false
	end

	local hit, result = sm.localPlayer.getRaycast( self.raycastRange )
	if not hit then return true end

	local target = result:getBody() or result:getCharacter()
	if not target or type(target) == "Body" and not target:isDynamic() then return true end

	if not self.target then
		sm.gui.setInteractionText("", sm.gui.getKeyBinding("Create", true), "Pick up target")
		if lmb == 1  then
			self.target = target
			self.network:sendToServer( "sv_targetSelect", target )
			sm.gui.displayAlertText("#00ff00Target selected!", 2.5)
			sm.audio.play("Blueprint - Camera")
		end
	end

	return true
end

function Grav:cl_mode_tumble()
	local hit, result = sm.localPlayer.getRaycast( self.raycastRange )
	if not hit then return end

	local target = result:getCharacter()
	if not target then return end

	self.network:sendToServer( "sv_targetTumble", target )
	sm.gui.displayAlertText("#00ff00Target tumbled!", 2.5)
	sm.audio.play("Blueprint - Open")
end

function Grav:cl_mode_copyrightInfringement( override )
	local start = sm.localPlayer.getRaycastStart()
	local endPos = start + sm.localPlayer.getDirection() * 50
	local hit, result = sm.physics.raycast( start, endPos, sm.localPlayer.getPlayer().character )

	if self.copyTarget and not override then
		sm.gui.displayAlertText("Pasted Object!", 2.5)
		sm.audio.play("Blueprint - Open")
		self.network:sendToServer("sv_pasteTarget", hit and result.pointWorld or endPos)
		return
	end

	local target = result:getBody() or result:getCharacter()
	local isChar = type(target) == "Character"
	if target == nil or isChar and target:isPlayer() then return end

	if not override then
		self.copyTarget = target
		if isChar then
			self.network:sendToServer("sv_setCopyTarget", target:getCharacterType())
		else
			self.network:sendToServer("sv_setCopyTarget", target)
			self.copyTargetBodies = target:getCreationBodies()
		end
	else
		sm.gui.displayAlertText("Teleport Object Selected!", 2.5)
		sm.audio.play("Blueprint - Camera")
		return target
	end

	sm.gui.displayAlertText("Copied Object!", 2.5)
	sm.audio.play("Blueprint - Camera")
end

function Grav:cl_mode_copyrightInfringement_reset()
	if not self.copyTarget then return end

	self.copyTarget = nil
	self.copyTargetBodies = nil
	self.network:sendToServer("sv_setCopyTarget", nil)
	sm.gui.displayAlertText("Target cleared!", 2.5)
	sm.audio.play("Blueprint - Delete")
end

function Grav:cl_mode_delete()
	local hit, result = sm.localPlayer.getRaycast( self.raycastRange )
	if not hit then return end

	local target = result:getBody() or result:getCharacter()
	if not target or type(target) == "Character" and target:isPlayer() then return end

	self.network:sendToServer("sv_deleteObject", target)
	sm.gui.displayAlertText("Object deleted!", 2.5)
	sm.audio.play("Blueprint - Delete")
end

function Grav:cl_deleteObject( obj )
	local scale = 1
	local referencePoint = obj:getCenterOfMassPosition()
	local creation = { data = {}, pos = referencePoint, scale = 1 }
	for k, shape in pairs(obj:getCreationShapes()) do
		local uuid = shape.uuid
		local effect = sm.effect.createEffect( "ShapeRenderable" )
		effect:setParameter("uuid", uuid)
		effect:setParameter("color", shape.color)
		local box = sm.item.isBlock(uuid) and shape:getBoundingBox() or sm.vec3.one() * 0.25
		effect:setScale( box * scale )
		--effect:setParameter( "boundingBox", shape:getBoundingBox() )
		effect:setRotation(shape.worldRotation)

		creation.data[#creation.data+1] = {
			effect = effect,
			box = box,
			pos = (shape.worldPosition - referencePoint) * scale
		}
	end

	self.deleteEffects[#self.deleteEffects+1] = creation
end

function Grav:cl_mode_teleport()
	if self.teleportObject then
		local hit, result = sm.localPlayer.getRaycast( self.raycastRange )
		if not hit then return end
		self.network:sendToServer("sv_deleteObject", { obj = self.teleportObject, override = true, pos = result.pointWorld })
		self.teleportObject = nil
	else
		self.teleportObject = self:cl_mode_copyrightInfringement( true )
	end
end

function Grav:cl_mode_blockReplace()
	local hit, result = sm.localPlayer.getRaycast( self.raycastRange )
	if hit and result.type == "body" then
		self.network:sendToServer(
			"sv_replaceBlocks",
			{
				body = result:getBody(),
				old = self.oldUuid,
				new = self.newUuid
			}
		)
	end
end


function Grav:client_onToggle()
	self.hoverRange = self.hoverRange > self.minHover and self.hoverRange - 1 or self.minHover
	sm.gui.displayAlertText("Hover range: #df7f00"..self.hoverRange, 2.5)
	sm.audio.play("Button off")
	self.network:sendToServer("sv_updateRange", self.hoverRange)

	return true
end

function Grav:client_onReload()
	self.hoverRange = self.hoverRange < self.maxHover and self.hoverRange + 1 or self.maxHover
	sm.gui.displayAlertText("Hover range: #df7f00"..self.hoverRange, 2.5)
	sm.audio.play("Button on")
	self.network:sendToServer("sv_updateRange", self.hoverRange)

	return true
end

function Grav:cl_targetSelect( target )
	self.target = target
end

function Grav.client_onUpdate( self, dt )
	local crouch =  self.tool:isCrouching()
	local equipped = self.tool:isEquipped()

	if self.isLocal then
		if self.target then
			local x, y = sm.localPlayer.getMouseDelta()
			if (x ~= 0 or y ~= 0) and sm.camera.getCameraState() == 2 then
				local sensitivity = sm.localPlayer.getAimSensitivity() * 100
				self.network:sendToServer("sv_syncMouseDelta", { x * sensitivity, y * sensitivity })
			end

			if not sm.exists(self.target) then
				self.target = nil
				self.network:sendToServer( "sv_targetSelect", nil )
			end
		end

		if self.mode == "Copy/Paste Object"  then
			if self.copyTarget and sm.exists(self.copyTarget) then
				self.copyTargetGui:setWorldPosition(type(self.copyTarget) == "Body" and self.copyTarget:getCenterOfMassPosition() or self.copyTarget.worldPosition)
				if not self.copyTargetGui:isActive() then self.copyTargetGui:open() end

				if self.copyTargetBodies and self.tool:isEquipped() then
					sm.visualization.setCreationBodies( self.copyTargetBodies )
					sm.visualization.setCreationFreePlacement( true )

					local start = sm.localPlayer.getRaycastStart()
					local endPos = start + sm.localPlayer.getDirection() * 50
					local hit, result = sm.physics.raycast( start, endPos, sm.localPlayer.getPlayer().character )
					sm.visualization.setCreationFreePlacementPosition( hit and result.pointWorld or endPos )
					sm.visualization.setCreationValid( true )
					sm.visualization.setCreationVisible( true )
				end
			elseif self.copyTargetGui:isActive() then
				self.copyTargetGui:close()
			end
		elseif self.mode == "Teleport" then
			if self.teleportObject and sm.exists(self.teleportObject) then
				if self.tool:isEquipped() and type(self.teleportObject) == "Body" then
					sm.visualization.setCreationBodies( self.teleportObject:getCreationBodies() )
					sm.visualization.setCreationFreePlacement( true )

					local start = sm.localPlayer.getRaycastStart()
					local endPos = start + sm.localPlayer.getDirection() * 50
					local hit, result = sm.physics.raycast( start, endPos, sm.localPlayer.getPlayer().character )
					sm.visualization.setCreationFreePlacementPosition( hit and result.pointWorld or endPos )
					sm.visualization.setCreationValid( true )
					sm.visualization.setCreationVisible( true )
				end
			elseif self.teleportObject ~= nil then
				self.teleportObject = nil
			end
		end

		self:updateFP(crouch, self.tool:isSprinting(), equipped, dt)
	end

	self:updateTP( crouch, dt )

	if self.target and sm.exists(self.target) then
		if equipped then
			local startPos = self.tool:isInFirstPersonView() and self.tool:getFpBonePos( "pipe" )  or self.tool:getTpBonePos( "pipe" )
			self.line:update( startPos, type(self.target) == "Character" and self.target.worldPosition or self.target:getCenterOfMassPosition(), dt, 100 )

			local col = self.line.colour
			self.tool:setTpColor(col)
			if self.isLocal then
				self.tool:setFpColor(col)
			end
		elseif self.line.effect:isPlaying() then
			self.line.effect:stop()
		end
	elseif self.line.effect:isPlaying() then
		self.line.effect:stop()
	end

	if #self.deleteEffects > 0 then
		for k, creation in pairs(self.deleteEffects) do
			creation.scale = creation.scale - dt * 5
			if creation.scale <= 0 then
				for i, data in pairs(creation.data) do
					data.effect:destroy()
				end
				table.remove(self.deleteEffects, k)
			else
				for i, data in pairs(creation.data) do
					local effect = data.effect
					effect:setPosition( creation.pos + data.pos * creation.scale )
					effect:setScale( data.box * creation.scale )
					effect:start()
				end
			end
		end
	end
end

function Grav.client_onEquip( self, animate )
	if animate then
		sm.audio.play( "PotatoRifle - Equip", self.tool:getPosition() )
	end

	local cameraWeight, cameraFPWeight = self.tool:getCameraWeights()
	self.aimWeight = math.max( cameraWeight, cameraFPWeight )
	self.jointWeight = 0.0

	local currentRenderablesTp = {}
	local currentRenderablesFp = {}

	for k,v in pairs( renderablesTp ) do currentRenderablesTp[#currentRenderablesTp+1] = v end
	for k,v in pairs( renderablesFp ) do currentRenderablesFp[#currentRenderablesFp+1] = v end
	for k,v in pairs( renderables ) do
		currentRenderablesTp[#currentRenderablesTp+1] = v
		currentRenderablesFp[#currentRenderablesFp+1] = v
	end

	self.tool:setTpRenderables( currentRenderablesTp )
	if self.isLocal then
		self.tool:setFpRenderables( currentRenderablesFp )
	end

	self:loadAnimations()
	setTpAnimation( self.tpAnimations, "pickup", 0.0001 )
	if self.isLocal then
		swapFpAnimation( self.fpAnimations, "unequip", "equip", 0.2 )
		self.network:sendToServer("sv_updateEquipped", true)
	end
end

function Grav.client_onUnequip( self, animate )
	if not sm.exists( self.tool ) then return end

	if animate then
		sm.audio.play( "PotatoRifle - Unequip", self.tool:getPosition() )
	end

	setTpAnimation( self.tpAnimations, "putdown" )

	if self.isLocal then
		self.tool:setMovementSlowDown( false )
		self.tool:setBlockSprint( false )
		self.tool:setCrossHairAlpha( 1.0 )
		self.tool:setInteractionTextSuppressed( false )
		if self.fpAnimations.currentAnimation ~= "unequip" then
			swapFpAnimation( self.fpAnimations, "equip", "unequip", 0.2 )
		end

		sm.camera.setCameraState(0)
		self.network:sendToServer("sv_updateEquipped", false)
	end
end

function Grav.cl_onPrimaryUse( self, state )
	if state ~= 1 then return end

	local func = self[self.modes[self.mode].onPrimary]
	if func then func( self ) end
end

function Grav.cl_onSecondaryUse( self, state )
	if state ~= 1 then return end

	local func = self[self.modes[self.mode].onSecondary]
	if func then func( self ) end
end

function Grav.client_onEquippedUpdate( self, lmb, rmb, f )
	if lmb ~= self.prevlmb then
		self:cl_onPrimaryUse( lmb )
		self.prevlmb = lmb
	end

	if rmb ~= self.prevrmb then
		self:cl_onSecondaryUse( rmb )
		self.prevrmb = rmb
	end

	local func = self[self.modes[self.mode].onEquipped]
	local guiToggleEnabled = true
	if func then
		guiToggleEnabled = func( self, lmb, rmb, f )
	end

	if guiToggleEnabled == true then
		if f and self.canTriggerFb and not self.blockF then
			self.canTriggerFb = false
			self.gui:open()
		elseif not f then
			self.canTriggerFb = true
			self.blockF = false
		end
	elseif self.gui:isActive() then
		self.gui:close()
	end

	return true, true
end




--fuck off
function Grav.loadAnimations( self )

	self.tpAnimations = createTpAnimations(
		self.tool,
		{
			idle = { "connecttool_idle" },
			pickup = { "connecttool_pickup", { nextAnimation = "idle" } },
			putdown = { "connecttool_putdown" }
		}
	)
	local movementAnimations = {
		idle = "connecttool_idle",
		--idleRelaxed = "connecttool_relax",

		sprint = "connecttool_sprint",
		runFwd = "connecttool_run_fwd",
		runBwd = "connecttool_run_bwd",

		jump = "connecttool_jump",
		jumpUp = "connecttool_jump_up",
		jumpDown = "connecttool_jump_down",

		land = "connecttool_jump_land",
		landFwd = "connecttool_jump_land_fwd",
		landBwd = "connecttool_jump_land_bwd",

		crouchIdle = "connecttool_crouch_idle",
		crouchFwd = "connecttool_crouch_fwd",
		crouchBwd = "connecttool_crouch_bwd"
	}

	for name, animation in pairs( movementAnimations ) do
		self.tool:setMovementAnimation( name, animation )
	end

	setTpAnimation( self.tpAnimations, "idle", 5.0 )

	if self.isLocal then
		self.fpAnimations = createFpAnimations(
			self.tool,
			{
				equip = { "connecttool_pickup", { nextAnimation = "idle" } },
				unequip = { "connecttool_putdown" },

				idle = { "connecttool_idle", { looping = true } },

				sprintInto = { "connecttool_sprint_into", { nextAnimation = "sprintIdle",  blendNext = 0.2 } },
				sprintExit = { "connecttool_sprint_exit", { nextAnimation = "idle",  blendNext = 0 } },
				sprintIdle = { "connecttool_sprint_idle", { looping = true } },
			}
		)
	end

	self.normalFireMode = {
		fireCooldown = 0.20,
		spreadCooldown = 0.18,
		spreadIncrement = 2.6,
		spreadMinAngle = .25,
		spreadMaxAngle = 8,
		fireVelocity = 130.0,

		minDispersionStanding = 0.1,
		minDispersionCrouching = 0.04,

		maxMovementDispersion = 0.4,
		jumpDispersionMultiplier = 2
	}

	self.movementDispersion = 0.0

	self.aimBlendSpeed = 3.0
	self.blendTime = 0.2

	self.jointWeight = 0.0
	self.spineWeight = 0.0
	local cameraWeight, cameraFPWeight = self.tool:getCameraWeights()
	self.aimWeight = math.max( cameraWeight, cameraFPWeight )

end

function Grav:updateTP( crouch, dt )
	local crouchWeight = crouch and 1.0 or 0.0
	local normalWeight = 1.0 - crouchWeight

	local totalWeight = 0.0
	for name, animation in pairs( self.tpAnimations.animations ) do
		animation.time = animation.time + dt

		if name == self.tpAnimations.currentAnimation then
			animation.weight = math.min( animation.weight + ( self.tpAnimations.blendSpeed * dt ), 1.0 )

			if animation.time >= animation.info.duration - self.blendTime then
                if name == "pickup" then
					setTpAnimation( self.tpAnimations, "idle", 0.001 )
				elseif animation.nextAnimation ~= "" then
					setTpAnimation( self.tpAnimations, animation.nextAnimation, 0.001 )
				end
			end
		else
			animation.weight = math.max( animation.weight - ( self.tpAnimations.blendSpeed * dt ), 0.0 )
		end

		totalWeight = totalWeight + animation.weight
	end

	totalWeight = totalWeight == 0 and 1.0 or totalWeight
	for name, animation in pairs( self.tpAnimations.animations ) do
		local weight = animation.weight / totalWeight
		if name == "idle" then
			self.tool:updateMovementAnimation( animation.time, weight )
		elseif animation.crouch then
			self.tool:updateAnimation( animation.info.name, animation.time, weight * normalWeight )
			self.tool:updateAnimation( animation.crouch.name, animation.time, weight * crouchWeight )
		else
			self.tool:updateAnimation( animation.info.name, animation.time, weight )
		end
	end
end

function Grav:updateFP(crouch, sprint, equipped, dt)
	if equipped then
		if sprint and self.fpAnimations.currentAnimation ~= "sprintInto" and self.fpAnimations.currentAnimation ~= "sprintIdle" then
			swapFpAnimation( self.fpAnimations, "sprintExit", "sprintInto", 0.0 )
		elseif not sprint and ( self.fpAnimations.currentAnimation == "sprintIdle" or self.fpAnimations.currentAnimation == "sprintInto" ) then
			swapFpAnimation( self.fpAnimations, "sprintInto", "sprintExit", 0.0 )
		end
	end
	updateFpAnimations( self.fpAnimations, equipped, dt )


	local dispersion = 0.0
	local fireMode = self.normalFireMode
	if crouch then
		dispersion = fireMode.minDispersionCrouching
	else
		dispersion = fireMode.minDispersionStanding
	end

	if self.tool:getRelativeMoveDirection():length() > 0 then
		dispersion = dispersion + fireMode.maxMovementDispersion * self.tool:getMovementSpeedFraction()
	end

	if not self.tool:isOnGround() then
		dispersion = dispersion * fireMode.jumpDispersionMultiplier
	end

	self.movementDispersion = dispersion
	self.tool:setDispersionFraction( clamp( self.movementDispersion, 0.0, 1.0 ) )
	self.tool:setCrossHairAlpha( 1.0 )
	self.tool:setInteractionTextSuppressed( false )


	local bobbing = 1
	local blend = 1 - (1 - 1 / self.aimBlendSpeed) ^ (dt * 60)
	self.aimWeight = sm.util.lerp( self.aimWeight, 0.0, blend )

	self.tool:updateCamera( 2.8, 30.0, sm.vec3.new( 0.65, 0.0, 0.05 ), self.aimWeight )
	self.tool:updateFpCamera( 30.0, sm.vec3.new( 0.0, 0.0, 0.0 ), self.aimWeight, bobbing )
end