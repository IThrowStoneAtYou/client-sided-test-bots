local module = {}
local remoteE = script:WaitForChild('RemoteE')
local pauselistener = script:WaitForChild('PauseListener')

local function finalize(Object,Prop)
	print(Object,Prop)
	for index, prop in Prop do
		Object[index] = prop
	end
end

function module:Create(Object: Instance, TweenInfo: TweenInfo, Properties: {[string]: any}, IsReplicated: boolean)
	local self = setmetatable(module,{})
	local Listener = Instance.new('RemoteEvent')
	local Completed = Instance.new('BindableEvent')
	local Finalized = false
	
	Listener.Parent = script
	Completed.Parent = script
	
	self.CapturedTime = math.floor(time() * 100)
	self.Object = Object
	self.Prop = Properties
	self.Time = TweenInfo.Time
	self.Finalized = false
	self.Completed = Completed.Event

	remoteE:FireAllClients(Object,{TweenInfo.Time,(TweenInfo.EasingStyle or Enum.EasingStyle.Linear).Name,(TweenInfo.EasingDirection or Enum.EasingDirection.In).Name,TweenInfo.RepeatCount or '0',if not TweenInfo.Reverses then 'false' else 'true'},Properties,self.CapturedTime,'make',Listener)
	Listener.OnServerEvent:Connect(function(player, object, prop)
		if not IsReplicated then 
			return 
		end
		
		if Finalized then 
			return 
		end

		self.Finalized = true

		finalize(object, prop)

		Completed:Fire()
		Listener:Destroy()
		Completed:Destroy()
		
		self = nil
	end)

	pauselistener.OnServerEvent:Connect(function(player, clientProp)
		if not IsReplicated then 
			return 
		end

		if Finalized then 
			return 
		end

		self.Finalized = true
		finalize(self.Object, clientProp)
	end)

	return self
end

function module:Play()
	self.Finalized = false
	remoteE:FireAllClients(nil,nil,nil,self.CapturedTime,'play')
end

function module:Pause()
	remoteE:FireAllClients(self.Object,nil,self.Prop,self.CapturedTime,'pause')
end

function module:Cancel()
	remoteE:FireAllClients(nil,nil,nil,self.CapturedTime,'cancel')
end

return module
