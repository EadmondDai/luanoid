local Workspace = game:GetService("Workspace")

local getModelMass = require(script.Parent.Parent.getModelMass)
local stepSpring = require(script.Parent.Parent.stepSpring)
local castCylinder = require(script.Parent.Parent.castCylinder)

local FRAMERATE = 1 / 240
local STIFFNESS = 170
local DAMPING = 26
local PRECISION = 0.001
local TARGET_SPEED = 24
local HIP_HEIGHT = 2.352
local MAX_HOR_ACCEL = TARGET_SPEED / 0.25 -- velocity / time to reach it squared
local MAX_VER_ACCELT = 50 / 0.1 -- massless max vertical force against gravity
local POP_TIME = 0.05 -- target time to reach target height

local THETA = math.pi * 2

-- loop between 0 - 2*pi
local function angleAbs(angle)
	while angle < 0 do
		angle = angle + THETA
	end
	while angle > THETA do
		angle = angle - THETA
	end
	return angle
end

local function angleShortest(a0, a1)
	local d1 = angleAbs(a1 - a0)
	local d2 = -angleAbs(a0 - a1)
	return math.abs(d1) > math.abs(d2) and d2 or d1
end

local function lerpAngle(a0, a1, alpha)
	return a0 + angleShortest(a0, a1)*alpha
end

local function makeCFrame(up, look)
	local upu = up.Unit
	local looku = (Vector3.new() - look).Unit
	local rightu = upu:Cross(looku).Unit
	-- orthonormalize, keeping up vector
	looku = -upu:Cross(rightu).Unit
	return CFrame.new(0, 0, 0, rightu.x, upu.x, looku.x, rightu.y, upu.y, looku.y, rightu.z, upu.z, looku.z)
end

local Walking = {}
Walking.__index = Walking

function Walking.new(simulation)
	local state = {
		simulation = simulation,
		character = simulation.character,
		accumulatedTime = 0,
		currentAccelerationX = 0,
		currentAccelerationY = 0,
		debugAdorns = {},
	}

	setmetatable(state, Walking)

	return state
end

function Walking:enterState()
	-- Elegance? Never heard of it.
	self.character.instance.LeftFoot.CanCollide = false
	self.character.instance.LeftLowerLeg.CanCollide = false
	self.character.instance.LeftUpperLeg.CanCollide = false
	self.character.instance.RightFoot.CanCollide = false
	self.character.instance.RightLowerLeg.CanCollide = false
	self.character.instance.RightUpperLeg.CanCollide = false

	self.character.orientation.Enabled = true
	self.character.vectorForce.Enabled = true
end

function Walking:leaveState()
	self.character.instance.LeftFoot.CanCollide = true
	self.character.instance.LeftLowerLeg.CanCollide = true
	self.character.instance.LeftUpperLeg.CanCollide = true
	self.character.instance.RightFoot.CanCollide = true
	self.character.instance.RightLowerLeg.CanCollide = true
	self.character.instance.RightUpperLeg.CanCollide = true

	self.character.orientation.Enabled = false
	self.character.vectorForce.Enabled = false
	self.character.vectorForce.Force = Vector3.new(0, 0, 0)

	for _, adorn in ipairs(self.debugAdorns) do
		adorn.instance:Destroy()
	end

	self.debugAdorns = {}
end

function Walking:step(dt, input)
	local characterMass = getModelMass(self.character.instance)

	local targetX = TARGET_SPEED * input.movementX
	local targetY = TARGET_SPEED * input.movementY

	self.accumulatedTime = self.accumulatedTime + dt

	local currentVelocity = self.character.instance.PrimaryPart.Velocity;
	local currentX = currentVelocity.X
	local currentY = currentVelocity.Z

	while self.accumulatedTime >= FRAMERATE do
		self.accumulatedTime = self.accumulatedTime - FRAMERATE

		currentX, self.currentAccelerationX = stepSpring(
			FRAMERATE,
			currentX,
			self.currentAccelerationX,
			targetX,
			STIFFNESS,
			DAMPING,
			PRECISION
		)

		currentY, self.currentAccelerationY = stepSpring(
			FRAMERATE,
			currentY,
			self.currentAccelerationY,
			targetY,
			STIFFNESS,
			DAMPING,
			PRECISION
		)
	end

	local vFactor = 0.075 -- fudge constant

	local onGround, groundHeight = castCylinder({
		origin = self.character.castPoint.WorldPosition,
		direction = Vector3.new(0, -5, 0),
		bias = Vector3.new(currentX*vFactor, 0, currentY*vFactor),
		adorns = self.debugAdorns,
		ignoreInstance = self.character.instance,
		hipHeight = HIP_HEIGHT,
	})

	local targetHeight = groundHeight + HIP_HEIGHT
	local currentHeight = self.character.castPoint.WorldPosition.Y

	local bottomColor = onGround and Color3.new(0, 1, 0) or Color3.new(1, 0, 0)
	self.character.instance.PrimaryPart.Color = bottomColor

	if onGround then
		local up

		local jumpHeight = 10
		local jumpInitialVelocity = math.sqrt(Workspace.Gravity*2*jumpHeight)
		if input.jump and currentVelocity.Y < jumpInitialVelocity then
			up = 0
			self.character.instance.PrimaryPart.Velocity = Vector3.new(currentX, jumpInitialVelocity, currentY)
		else
			local t = POP_TIME
			-- counter gravity and then solve constant acceleration eq (x1 = x0 + v*t + 0.5*a*t*t) for a to aproach target height over time
			up = Workspace.Gravity + 2*((targetHeight-currentHeight) - currentVelocity.Y*t)/(t*t)
			-- very low downward acceleration cuttoff (limited ability to push yourself down)
			if up < -1 then
				up = 0
			end
			up = up*characterMass
		end

		self.character.vectorForce.Force = Vector3.new(
			self.currentAccelerationX * characterMass,
			up,
			self.currentAccelerationY * characterMass
		)
	else
		self.character.vectorForce.Force = Vector3.new(0, 0, 0)
	end

	local velocity = Vector3.new(currentX, 0, currentY)
	local lookVector = self.character.instance.PrimaryPart.CFrame.lookVector

	if velocity.Magnitude > 0.1 and lookVector.y < 0.9 then
		-- Fix "tumbling" where AlignOrientation might pick the "wrong" axis when we cross through 0, lerp angles...
		local currentAngle = math.atan2(lookVector.z, lookVector.x)
		local targetAngle = math.atan2(currentY, currentX)
		-- If we crossed through 0 (shortest arc angle is close to pi) then lerp the angle...
		if math.abs(angleShortest(currentAngle, targetAngle)) > math.pi*0.95 then
			targetAngle = lerpAngle(currentAngle, targetAngle, 0.95)
		end

		local up = Vector3.new(0, 1, 0)
		local look = Vector3.new(math.cos(targetAngle), 0, math.sin(targetAngle))
		self.character.orientationAttachment.CFrame = makeCFrame(up, look)
	end

	if input.ragdoll then
		self.simulation:setState("Ragdoll")
	end
end

return Walking