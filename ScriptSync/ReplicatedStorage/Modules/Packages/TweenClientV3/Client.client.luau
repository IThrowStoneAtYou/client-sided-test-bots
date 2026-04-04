local TweenService = game:GetService('TweenService')
local Remote = script.Parent:WaitForChild('RemoteE')
local PauseListener = script.Parent:WaitForChild('PauseListener')

local Cache: {Tween} = {}

Remote.OnClientEvent:Connect(function(Object,Tweeninfo,Property,CapturedTime,Methods,Listener)
	if Methods == 'play' then
		Cache[CapturedTime]:Play()
		return
	end

	if Methods == 'pause' then
		local clientprop = {}
		
		Cache[CapturedTime]:Pause()
		for index, prop in Property do
			clientprop[index] = Object[index]
		end
		PauseListener:FireServer(clientprop)
	end

	if Methods == 'cancel' then
		Cache[CapturedTime]:Cancel()
		Cache[CapturedTime] = nil
		Listener:FireServer()
	end

	if Methods == 'make' then
		Cache[CapturedTime] = TweenService:Create(Object,TweenInfo.new(Tweeninfo[1],Enum.EasingStyle[Tweeninfo[2]],Enum.EasingDirection[Tweeninfo[3]],Tweeninfo[4],if TweenInfo[5] == 'false' then true else false),Property)
		Cache[CapturedTime].Completed:Once(function()
			Listener:FireServer(Object,Property)
		end)
		
		return
	end
end)