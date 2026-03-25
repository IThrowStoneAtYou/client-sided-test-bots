local Ragdoll = {}

function Ragdoll.Apply(model: Model)
	for _, joint in ipairs(model:GetDescendants()) do
		if joint:IsA("Motor6D") then
			local a1 = Instance.new("Attachment")
			local a2 = Instance.new("Attachment")
			a1.CFrame = joint.C0
			a2.CFrame = joint.C1
			a1.Parent = joint.Part0
			a2.Parent = joint.Part1

			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = a1
			socket.Attachment1 = a2
			socket.LimitsEnabled = true
			socket.TwistLimitsEnabled = true
			socket.Parent = joint.Parent
			
			print("ragdoll")

			joint:Destroy()
		end
	end
end

return Ragdoll