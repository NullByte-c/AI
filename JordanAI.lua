local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")

local player = Players.LocalPlayer
if not player then
    return
end

local playerGui = player:WaitForChild("PlayerGui")

local GAME_NAME = nil

task.spawn(function()
    local ok, info = pcall(function()
        return MarketplaceService:GetProductInfo(game.PlaceId)
    end)

    if ok and info and type(info.Name) == "string" and info.Name ~= "" then
        GAME_NAME = info.Name
    end
end)

local function getRequest()
    if request then
        return request
    end

    if http_request then
        return http_request
    end

    if syn and syn.request then
        return syn.request
    end

    if http and http.request then
        return http.request
    end

    return nil
end

local PROVIDERS = {
    groq = {
        name = "Groq",
        url = "https://api.groq.com/openai/v1/chat/completions",
        models = {
            "openai/gpt-oss-120b",
            "openai/gpt-oss-20b",
            "groq/compound",
            "groq/compound-mini"
        }
    },
    openrouter = {
        name = "OpenRouter",
        url = "https://openrouter.ai/api/v1/chat/completions",
        models = {
            "liquid/lfm-2.5-2.6b:free",
            "dots-studio/dots-3-note-preview:free",
            "thinkingmachines/inkling-small:free"
        }
    }
}

for _, provider in pairs(PROVIDERS) do
    provider.defaultModel = provider.models[1]
end

local PROVIDER_ORDER = {"groq", "openrouter"}

local MODEL_ALIASES = {
    groq = {
        ["openai/gpt-oss-120b"] = "gptoss_120b",
        ["openai/gpt-oss-20b"] = "gptoss_20b",
        ["groq/compound"] = "compound",
        ["groq/compound-mini"] = "compound_mini"
    },
    openrouter = {
        ["liquid/lfm-2.5-2.6b:free"] = "lfm25_2b",
        ["dots-studio/dots-3-note-preview:free"] = "dots3_note",
        ["thinkingmachines/inkling-small:free"] = "inkling_small"
    }
}

local function aliasForModel(providerKey, modelName)
    local aliases = MODEL_ALIASES[providerKey]
    return aliases and aliases[modelName] or modelName
end

local function modelForAlias(providerKey, alias)
    local aliases = MODEL_ALIASES[providerKey]

    if not aliases then
        return nil
    end

    local loweredAlias = alias:lower()

    for modelName, modelAlias in pairs(aliases) do
        if modelAlias:lower() == loweredAlias then
            return modelName
        end
    end

    return nil
end

local function loadSettings()
    local defaults = {
        provider = "groq",
        groqApi = "",
        groqModel = PROVIDERS.groq.defaultModel,
        openrouterApi = "",
        openrouterModel = PROVIDERS.openrouter.defaultModel,
        prompt = "You are a helpful AI assistant.",
        enabled = true,
        range = 0,
        cooldown = 6,
        disabledActions = {},
        admins = {},
        blacklist = {},
        botName = "Jordan",
        idleGestures = false
    }

    if not isfile or not readfile then
        return defaults
    end

    local okFile, exists = pcall(function()
        return isfile("JordanAI_Config.json")
    end)

    if not okFile or not exists then
        return defaults
    end

    local ok, result = pcall(function()
        return HttpService:JSONDecode(
            readfile("JordanAI_Config.json")
        )
    end)

    if ok and type(result) == "table" then
        for k, v in pairs(defaults) do
            if result[k] == nil then
                result[k] = v
            end
        end

        return result
    end

    return defaults
end

local settings = loadSettings()
local speakInGameChat
local lastInteractionTime = os.clock()

if not PROVIDERS[settings.provider] then
    settings.provider = "groq"
end

local KNOWN_STALE_MODELS = {
    groq = {
        ["gemma2-9b-it"] = true,
        ["mixtral-8x7b-32768"] = true,
        ["llama-3.3-70b-versatile"] = true,
        ["llama-3.1-8b-instant"] = true
    },
    openrouter = {
        ["meta-llama/llama-3.3-70b-instruct:free"] = true,
        ["google/gemini-2.0-flash-exp:free"] = true,
        ["mistralai/mistral-7b-instruct:free"] = true,
        ["qwen/qwen-2.5-72b-instruct:free"] = true,
        ["nvidia/nemotron-3.5-lightning:free"] = true,
        ["nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free"] = true
    }
}

for _, key in ipairs(PROVIDER_ORDER) do
    if settings[key .. "Api"] == nil then
        settings[key .. "Api"] = ""
    end

    if settings[key .. "Model"] == nil then
        settings[key .. "Model"] = PROVIDERS[key].defaultModel
    elseif KNOWN_STALE_MODELS[key] and KNOWN_STALE_MODELS[key][settings[key .. "Model"]] then
        settings[key .. "Model"] = PROVIDERS[key].defaultModel
    end
end

if type(settings.disabledActions) ~= "table" then
    settings.disabledActions = {}
end

if type(settings.admins) ~= "table" then
    settings.admins = {}
end

for _, entry in ipairs(settings.admins) do
    if type(entry.allowedModels) ~= "table" then
        entry.allowedModels = {}
    end

    if type(entry.canChangeProvider) ~= "boolean" then
        entry.canChangeProvider = true
    end

    if type(entry.canChangeModel) ~= "boolean" then
        entry.canChangeModel = true
    end
end

if type(settings.blacklist) ~= "table" then
    settings.blacklist = {}
end

if type(settings.botName) ~= "string" or settings.botName == "" then
    settings.botName = "Jordan"
end

if type(settings.idleGestures) ~= "boolean" then
    settings.idleGestures = false
end

local MAX_HISTORY = 12
local MAX_USER_MESSAGE_LEN = 400
local MAX_REPLY_TOKENS = 250
local conversations = {}

local function getConversation(userId)
    if not conversations[userId] then
        conversations[userId] = {}
    end

    return conversations[userId]
end

local MAX_STORED_MESSAGE_LEN = 300

local function pushMessage(convo, role, content)
    if #content > MAX_STORED_MESSAGE_LEN then
        content = content:sub(1, MAX_STORED_MESSAGE_LEN) .. "..."
    end

    table.insert(convo, {role = role, content = content})

    while #convo > MAX_HISTORY do
        table.remove(convo, 1)
    end
end

local function saveSettings()
    if not writefile then
        return false
    end

    local ok = pcall(function()
        writefile(
            "JordanAI_Config.json",
            HttpService:JSONEncode(settings)
        )
    end)

    return ok
end

local oldGui = playerGui:FindFirstChild("JordanAI")
if oldGui then
    oldGui:Destroy()
end

local gui = Instance.new("ScreenGui")
gui.Name = "JordanAI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local FONT_SIZE = 12

local function round(obj, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius)
    c.Parent = obj
    return c
end

local function outline(obj, colour, thickness)
    local s = Instance.new("UIStroke")
    s.Color = colour
    s.Thickness = thickness or 1
    s.Parent = obj
    return s
end

local function button(parent, text, size, position)
    local baseColor = Color3.fromRGB(38, 38, 38)
    local hoverColor = Color3.fromRGB(48, 48, 48)

    local b = Instance.new("TextButton")
    b.Size = size
    b.Position = position
    b.BackgroundColor3 = baseColor
    b.BorderSizePixel = 0
    b.Text = text
    b.TextColor3 = Color3.fromRGB(205, 205, 205)
    b.TextSize = FONT_SIZE
    b.Font = Enum.Font.GothamMedium
    b.AutoButtonColor = false
    b.Parent = parent

    round(b, 7)
    outline(b, Color3.fromRGB(65, 65, 65), 1)

    local scale = Instance.new("UIScale")
    scale.Parent = b

    b.MouseEnter:Connect(function()
        TweenService:Create(b, TweenInfo.new(0.12), {BackgroundColor3 = hoverColor}):Play()
    end)

    b.MouseLeave:Connect(function()
        TweenService:Create(b, TweenInfo.new(0.12), {BackgroundColor3 = baseColor}):Play()
        TweenService:Create(scale, TweenInfo.new(0.12), {Scale = 1}):Play()
    end)

    b.MouseButton1Down:Connect(function()
        TweenService:Create(scale, TweenInfo.new(0.08), {Scale = 0.95}):Play()
    end)

    b.MouseButton1Up:Connect(function()
        TweenService:Create(scale, TweenInfo.new(0.12), {Scale = 1}):Play()
    end)

    return b
end

local function textbox(parent, placeholder, text, size, position, multiline)
    local b = Instance.new("TextBox")
    b.Size = size
    b.Position = position
    b.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    b.BorderSizePixel = 0
    b.Text = text or ""
    b.PlaceholderText = placeholder
    b.PlaceholderColor3 = Color3.fromRGB(90, 90, 90)
    b.TextColor3 = Color3.fromRGB(205, 205, 205)
    b.TextSize = FONT_SIZE
    b.Font = Enum.Font.Gotham
    b.ClearTextOnFocus = false
    b.MultiLine = multiline or false
    b.TextXAlignment = Enum.TextXAlignment.Left
    b.TextYAlignment = multiline and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center
    b.Parent = parent

    round(b, 7)
    outline(b, Color3.fromRGB(55, 55, 55), 1)

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 8)
    padding.PaddingRight = UDim.new(0, 8)
    padding.PaddingTop = UDim.new(0, 6)
    padding.PaddingBottom = UDim.new(0, 6)
    padding.Parent = b

    return b
end

local function label(parent, text, size, position, fontSize)
    local l = Instance.new("TextLabel")
    l.Size = size
    l.Position = position
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = Color3.fromRGB(170, 170, 170)
    l.TextSize = fontSize or FONT_SIZE
    l.Font = Enum.Font.Gotham
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = parent
    return l
end

local function makeWindow(name, titleText, size, minSize, maxSize)
    local frame = Instance.new("Frame")
    frame.Name = name
    frame.Active = true
    frame.AnchorPoint = Vector2.new(0.5, 0.5)
    frame.Size = size
    frame.Position = UDim2.new(0.5, 0, 0.5, 0)
    frame.BackgroundColor3 = Color3.fromRGB(17, 17, 17)
    frame.BorderSizePixel = 0
    frame.Parent = gui

    round(frame, 12)
    outline(frame, Color3.fromRGB(68, 68, 68), 1.5)

    if minSize or maxSize then
        local constraint = Instance.new("UISizeConstraint")
        constraint.MinSize = minSize or Vector2.new(0, 0)
        constraint.MaxSize = maxSize or Vector2.new(math.huge, math.huge)
        constraint.Parent = frame
    end

    local dragging = false
    local dragStart = nil
    local startPosition = nil

    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = frame.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart

            frame.Position = UDim2.new(
                startPosition.X.Scale,
                startPosition.X.Offset + delta.X,
                startPosition.Y.Scale,
                startPosition.Y.Offset + delta.Y
            )
        end
    end)

    local title = label(
        frame,
        titleText,
        UDim2.new(1, -24, 0, 26),
        UDim2.new(0, 12, 0, 6),
        15
    )

    title.Font = Enum.Font.GothamBold
    title.TextColor3 = Color3.fromRGB(220, 220, 220)

    return frame
end

local function makeSlider(parent, title, y, minValue, maxValue, initialValue, valueText, onChange)
    label(parent, title, UDim2.new(0.5, 0, 0, 20), UDim2.new(0, 0, 0, y))

    local valueLabel = label(parent, "", UDim2.new(0.5, 0, 0, 20), UDim2.new(0.5, 0, 0, y))
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(1, 0, 0, 6)
    bar.Position = UDim2.new(0, 0, 0, y + 28)
    bar.BackgroundColor3 = Color3.fromRGB(43, 43, 43)
    bar.BorderSizePixel = 0
    bar.Parent = parent
    round(bar, 4)

    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
    fill.BorderSizePixel = 0
    fill.Parent = bar
    round(fill, 4)

    local knob = Instance.new("TextButton")
    knob.Size = UDim2.new(0, 15, 0, 15)
    knob.BackgroundColor3 = Color3.fromRGB(175, 175, 175)
    knob.BorderSizePixel = 0
    knob.Text = ""
    knob.Parent = bar
    round(knob, 8)

    local dragging = false

    local function update(value)
        value = math.clamp(math.floor(value + 0.5), minValue, maxValue)
        local ratio = (value - minValue) / (maxValue - minValue)

        fill.Size = UDim2.new(ratio, 0, 1, 0)
        knob.Position = UDim2.new(ratio, -7, 0.5, -7)
        valueLabel.Text = valueText(value)

        onChange(value)

        return value
    end

    local function fromX(x)
        local ratio = math.clamp(
            (x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X,
            0,
            1
        )

        update(minValue + ratio * (maxValue - minValue))
    end

    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            fromX(input.Position.X)
        end
    end)

    knob.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            fromX(input.Position.X)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    update(initialValue)

    return update
end

local notifyContainer = Instance.new("Frame")
notifyContainer.Size = UDim2.new(0, 220, 1, -20)
notifyContainer.Position = UDim2.new(1, -236, 0, 10)
notifyContainer.BackgroundTransparency = 1
notifyContainer.Parent = gui

local notifyLayout = Instance.new("UIListLayout")
notifyLayout.Padding = UDim.new(0, 6)
notifyLayout.SortOrder = Enum.SortOrder.LayoutOrder
notifyLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
notifyLayout.Parent = notifyContainer

local NOTIFY_COLORS = {
    info = Color3.fromRGB(45, 45, 45),
    success = Color3.fromRGB(35, 90, 58),
    error = Color3.fromRGB(105, 40, 40)
}

local notifyCounter = 0

local function notify(text, kind)
    kind = kind or "info"
    notifyCounter = notifyCounter + 1

    local card = Instance.new("Frame")
    card.LayoutOrder = notifyCounter
    card.Size = UDim2.new(1, 0, 0, 0)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.BackgroundColor3 = NOTIFY_COLORS[kind] or NOTIFY_COLORS.info
    card.BackgroundTransparency = 1
    card.BorderSizePixel = 0
    card.ClipsDescendants = true
    card.Parent = notifyContainer

    round(card, 7)
    local stroke = outline(card, Color3.fromRGB(70, 70, 70), 1)
    stroke.Transparency = 1

    local textLabel = Instance.new("TextLabel")
    textLabel.Size = UDim2.new(1, -16, 0, 0)
    textLabel.AutomaticSize = Enum.AutomaticSize.Y
    textLabel.Position = UDim2.new(0, 8, 0, 6)
    textLabel.BackgroundTransparency = 1
    textLabel.Text = text
    textLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
    textLabel.TextSize = FONT_SIZE
    textLabel.Font = Enum.Font.GothamMedium
    textLabel.TextWrapped = true
    textLabel.TextXAlignment = Enum.TextXAlignment.Left
    textLabel.TextTransparency = 1
    textLabel.Parent = card

    local padding = Instance.new("UIPadding")
    padding.PaddingBottom = UDim.new(0, 6)
    padding.Parent = card

    card.Position = UDim2.new(0.15, 0, 0, 0)

    TweenService:Create(card, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        BackgroundTransparency = 0.05,
        Position = UDim2.new(0, 0, 0, 0)
    }):Play()

    TweenService:Create(stroke, TweenInfo.new(0.25), {Transparency = 0.3}):Play()
    TweenService:Create(textLabel, TweenInfo.new(0.25), {TextTransparency = 0}):Play()

    task.delay(4, function()
        if not card.Parent then
            return
        end

        local outTween = TweenService:Create(card, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            BackgroundTransparency = 1,
            Position = UDim2.new(0.15, 0, 0, 0)
        })

        TweenService:Create(stroke, TweenInfo.new(0.2), {Transparency = 1}):Play()
        TweenService:Create(textLabel, TweenInfo.new(0.2), {TextTransparency = 1}):Play()

        outTween:Play()
        outTween.Completed:Wait()
        card:Destroy()
    end)
end

local aiWindow = makeWindow(
    "AIWindow",
    "AI Chatbot made by Jordan",
    UDim2.new(0.8, 0, 0.68, 0),
    Vector2.new(300, 360),
    Vector2.new(360, 440)
)

aiWindow.Visible = false

local tabs = Instance.new("Frame")
tabs.Size = UDim2.new(1, -24, 0, 30)
tabs.Position = UDim2.new(0, 12, 0, 38)
tabs.BackgroundTransparency = 1
tabs.Parent = aiWindow

local chatTab = button(
    tabs,
    "Chat",
    UDim2.new(0.2, -3, 1, 0),
    UDim2.new(0, 0, 0, 0)
)

local settingsTab = button(
    tabs,
    "Settings",
    UDim2.new(0.2, -3, 1, 0),
    UDim2.new(0.2, 0, 0, 0)
)

local actionsTab = button(
    tabs,
    "Actions",
    UDim2.new(0.2, -3, 1, 0),
    UDim2.new(0.4, 0, 0, 0)
)

local adminsTab = button(
    tabs,
    "Admins",
    UDim2.new(0.2, -3, 1, 0),
    UDim2.new(0.6, 0, 0, 0)
)

local creditsTab = button(
    tabs,
    "Credits",
    UDim2.new(0.2, -3, 1, 0),
    UDim2.new(0.8, 0, 0, 0)
)

local function newPageFrame()
    local ok, inst = pcall(Instance.new, "CanvasGroup")

    if ok and inst then
        return inst
    end

    return Instance.new("Frame")
end

local chatPage = newPageFrame()
chatPage.Size = UDim2.new(1, -24, 1, -78)
chatPage.Position = UDim2.new(0, 12, 0, 74)
chatPage.BackgroundTransparency = 1
chatPage.Parent = aiWindow

local settingsPage = newPageFrame()
settingsPage.Size = UDim2.new(1, -24, 1, -78)
settingsPage.Position = UDim2.new(0, 12, 0, 74)
settingsPage.BackgroundTransparency = 1
settingsPage.Visible = false
settingsPage.Parent = aiWindow

local settingsScroll = Instance.new("ScrollingFrame")
settingsScroll.Size = UDim2.new(1, 0, 1, 0)
settingsScroll.BackgroundTransparency = 1
settingsScroll.BorderSizePixel = 0
settingsScroll.ScrollBarThickness = 3
settingsScroll.ScrollBarImageColor3 = Color3.fromRGB(75, 75, 75)
settingsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
settingsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
settingsScroll.Parent = settingsPage

local actionsPage = newPageFrame()
actionsPage.Size = UDim2.new(1, -24, 1, -78)
actionsPage.Position = UDim2.new(0, 12, 0, 74)
actionsPage.BackgroundTransparency = 1
actionsPage.Visible = false
actionsPage.Parent = aiWindow

local actionsScroll = Instance.new("ScrollingFrame")
actionsScroll.Size = UDim2.new(1, 0, 1, -38)
actionsScroll.BackgroundTransparency = 1
actionsScroll.BorderSizePixel = 0
actionsScroll.ScrollBarThickness = 3
actionsScroll.ScrollBarImageColor3 = Color3.fromRGB(75, 75, 75)
actionsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
actionsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
actionsScroll.Parent = actionsPage

local actionsListLayout = Instance.new("UIListLayout")
actionsListLayout.Padding = UDim.new(0, 4)
actionsListLayout.SortOrder = Enum.SortOrder.Name
actionsListLayout.Parent = actionsScroll

local actionsBulkRow = Instance.new("Frame")
actionsBulkRow.Size = UDim2.new(1, 0, 0, 30)
actionsBulkRow.Position = UDim2.new(0, 0, 1, -30)
actionsBulkRow.BackgroundTransparency = 1
actionsBulkRow.Parent = actionsPage

local enableAllButton = button(
    actionsBulkRow,
    "Approve All",
    UDim2.new(0.49, 0, 1, 0),
    UDim2.new(0, 0, 0, 0)
)

local disableAllButton = button(
    actionsBulkRow,
    "Disable All",
    UDim2.new(0.49, 0, 1, 0),
    UDim2.new(0.51, 0, 0, 0)
)

local adminsPage = newPageFrame()
adminsPage.Size = UDim2.new(1, -24, 1, -78)
adminsPage.Position = UDim2.new(0, 12, 0, 74)
adminsPage.BackgroundTransparency = 1
adminsPage.Visible = false
adminsPage.Parent = aiWindow

local adminsScroll = Instance.new("ScrollingFrame")
adminsScroll.Size = UDim2.new(1, 0, 1, 0)
adminsScroll.BackgroundTransparency = 1
adminsScroll.BorderSizePixel = 0
adminsScroll.ScrollBarThickness = 3
adminsScroll.ScrollBarImageColor3 = Color3.fromRGB(75, 75, 75)
adminsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
adminsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
adminsScroll.Parent = adminsPage

local adminsOuterLayout = Instance.new("UIListLayout")
adminsOuterLayout.Padding = UDim.new(0, 10)
adminsOuterLayout.SortOrder = Enum.SortOrder.LayoutOrder
adminsOuterLayout.Parent = adminsScroll

local grantAdminRow = Instance.new("Frame")
grantAdminRow.Size = UDim2.new(1, 0, 0, 54)
grantAdminRow.BackgroundTransparency = 1
grantAdminRow.LayoutOrder = 1
grantAdminRow.Parent = adminsScroll

label(grantAdminRow, "Grant Admin (username)", UDim2.new(1, 0, 0, 16), UDim2.new(0, 0, 0, 0))

local adminNameBox = textbox(
    grantAdminRow,
    "Username",
    "",
    UDim2.new(0.62, -4, 0, 30),
    UDim2.new(0, 0, 0, 20)
)

local grantAdminButton = button(
    grantAdminRow,
    "Grant",
    UDim2.new(0.38, -4, 0, 30),
    UDim2.new(0.62, 4, 0, 20)
)

local adminRowsContainer = Instance.new("Frame")
adminRowsContainer.Size = UDim2.new(1, 0, 0, 0)
adminRowsContainer.AutomaticSize = Enum.AutomaticSize.Y
adminRowsContainer.BackgroundTransparency = 1
adminRowsContainer.LayoutOrder = 2
adminRowsContainer.Parent = adminsScroll

local adminRowsLayout = Instance.new("UIListLayout")
adminRowsLayout.Padding = UDim.new(0, 4)
adminRowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
adminRowsLayout.Parent = adminRowsContainer

local blacklistAddRow = Instance.new("Frame")
blacklistAddRow.Size = UDim2.new(1, 0, 0, 54)
blacklistAddRow.BackgroundTransparency = 1
blacklistAddRow.LayoutOrder = 3
blacklistAddRow.Parent = adminsScroll

label(blacklistAddRow, "Blacklist (username)", UDim2.new(1, 0, 0, 16), UDim2.new(0, 0, 0, 0))

local blacklistNameBox = textbox(
    blacklistAddRow,
    "Username",
    "",
    UDim2.new(0.62, -4, 0, 30),
    UDim2.new(0, 0, 0, 20)
)

local blacklistAddButton = button(
    blacklistAddRow,
    "Block",
    UDim2.new(0.38, -4, 0, 30),
    UDim2.new(0.62, 4, 0, 20)
)

local blacklistRowsContainer = Instance.new("Frame")
blacklistRowsContainer.Size = UDim2.new(1, 0, 0, 0)
blacklistRowsContainer.AutomaticSize = Enum.AutomaticSize.Y
blacklistRowsContainer.BackgroundTransparency = 1
blacklistRowsContainer.LayoutOrder = 4
blacklistRowsContainer.Parent = adminsScroll

local blacklistRowsLayout = Instance.new("UIListLayout")
blacklistRowsLayout.Padding = UDim.new(0, 4)
blacklistRowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
blacklistRowsLayout.Parent = blacklistRowsContainer

local creditsPage = newPageFrame()
creditsPage.Size = UDim2.new(1, -24, 1, -78)
creditsPage.Position = UDim2.new(0, 12, 0, 74)
creditsPage.BackgroundTransparency = 1
creditsPage.Visible = false
creditsPage.Parent = aiWindow

local history = Instance.new("ScrollingFrame")
history.Size = UDim2.new(1, 0, 1, -50)
history.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
history.BorderSizePixel = 0
history.ScrollBarThickness = 3
history.ScrollBarImageColor3 = Color3.fromRGB(75, 75, 75)
history.AutomaticCanvasSize = Enum.AutomaticSize.Y
history.CanvasSize = UDim2.new(0, 0, 0, 0)
history.Parent = chatPage

round(history, 8)
outline(history, Color3.fromRGB(48, 48, 48), 1)

local historyLayout = Instance.new("UIListLayout")
historyLayout.Padding = UDim.new(0, 6)
historyLayout.SortOrder = Enum.SortOrder.LayoutOrder
historyLayout.Parent = history

local historyPadding = Instance.new("UIPadding")
historyPadding.PaddingTop = UDim.new(0, 6)
historyPadding.PaddingBottom = UDim.new(0, 6)
historyPadding.PaddingLeft = UDim.new(0, 6)
historyPadding.PaddingRight = UDim.new(0, 6)
historyPadding.Parent = history

local messageBox = textbox(
    chatPage,
    "Ask the AI something...",
    "",
    UDim2.new(1, -76, 0, 38),
    UDim2.new(0, 0, 1, -40),
    false
)

local sendButton = button(
    chatPage,
    "Send",
    UDim2.new(0, 68, 0, 38),
    UDim2.new(1, -68, 1, -40)
)

local MAX_DISPLAYED_MESSAGES = 60

local function addMessage(author, text)
    local item = Instance.new("TextLabel")
    item.Size = UDim2.new(1, -2, 0, 0)
    item.AutomaticSize = Enum.AutomaticSize.Y
    item.BackgroundColor3 = Color3.fromRGB(29, 29, 29)
    item.BorderSizePixel = 0
    item.Text = author .. "\n" .. text
    item.TextColor3 = Color3.fromRGB(195, 195, 195)
    item.TextSize = FONT_SIZE
    item.Font = Enum.Font.Gotham
    item.TextWrapped = true
    item.TextXAlignment = Enum.TextXAlignment.Left
    item.TextYAlignment = Enum.TextYAlignment.Top
    item.Parent = history

    round(item, 6)

    local p = Instance.new("UIPadding")
    p.PaddingLeft = UDim.new(0, 7)
    p.PaddingRight = UDim.new(0, 7)
    p.PaddingTop = UDim.new(0, 6)
    p.PaddingBottom = UDim.new(0, 6)
    p.Parent = item

    task.defer(function()
        history.CanvasPosition = Vector2.new(
            0,
            math.max(0, history.AbsoluteCanvasSize.Y)
        )
    end)

    local labels = {}

    for _, child in ipairs(history:GetChildren()) do
        if child:IsA("TextLabel") then
            table.insert(labels, child)
        end
    end

    while #labels > MAX_DISPLAYED_MESSAGES do
        local oldest = table.remove(labels, 1)
        oldest:Destroy()
    end
end

local function clearHistory()
    for _, child in ipairs(history:GetChildren()) do
        if child:IsA("TextLabel") then
            child:Destroy()
        end
    end
end

label(
    settingsScroll,
    "AI Provider",
    UDim2.new(0.5, 0, 0, 20),
    UDim2.new(0, 0, 0, 0)
)

local providerButton = button(
    settingsScroll,
    "",
    UDim2.new(0, 100, 0, 26),
    UDim2.new(1, -100, 0, -2)
)

label(
    settingsScroll,
    "API Key",
    UDim2.new(1, 0, 0, 16),
    UDim2.new(0, 0, 0, 34)
)

local apiBox = textbox(
    settingsScroll,
    "",
    "",
    UDim2.new(1, 0, 0, 32),
    UDim2.new(0, 0, 0, 52)
)

label(
    settingsScroll,
    "Model Name",
    UDim2.new(1, 0, 0, 16),
    UDim2.new(0, 0, 0, 92)
)

local modelBox = textbox(
    settingsScroll,
    "",
    "",
    UDim2.new(1, 0, 0, 32),
    UDim2.new(0, 0, 0, 110)
)

label(
    settingsScroll,
    "System Prompt",
    UDim2.new(1, 0, 0, 16),
    UDim2.new(0, 0, 0, 150)
)

local promptBox = textbox(
    settingsScroll,
    "Tell the AI how it should behave...",
    settings.prompt,
    UDim2.new(1, 0, 0, 62),
    UDim2.new(0, 0, 0, 168),
    true
)

local function refreshProviderFields()
    providerButton.Text = PROVIDERS[settings.provider].name
    apiBox.Text = settings[settings.provider .. "Api"]

    if settings.provider == "groq" then
        apiBox.PlaceholderText = "Groq key(s), comma-separated for multiple"
    else
        apiBox.PlaceholderText = "Paste your " .. PROVIDERS[settings.provider].name .. " API key"
    end

    modelBox.Text = settings[settings.provider .. "Model"]
    modelBox.PlaceholderText = "Example: " .. PROVIDERS[settings.provider].defaultModel
end

providerButton.MouseButton1Click:Connect(function()
    settings[settings.provider .. "Api"] = apiBox.Text
    settings[settings.provider .. "Model"] = modelBox.Text

    local currentIndex = table.find(PROVIDER_ORDER, settings.provider) or 1
    local nextIndex = (currentIndex % #PROVIDER_ORDER) + 1
    settings.provider = PROVIDER_ORDER[nextIndex]

    refreshProviderFields()
    notify("Switched to " .. PROVIDERS[settings.provider].name, "info")
end)

refreshProviderFields()

label(
    settingsScroll,
    "AI Enabled",
    UDim2.new(0.5, 0, 0, 22),
    UDim2.new(0, 0, 0, 242)
)

local enabledButton = button(
    settingsScroll,
    "",
    UDim2.new(0, 64, 0, 26),
    UDim2.new(1, -64, 0, 240)
)

local function updateEnabled()
    if settings.enabled then
        enabledButton.Text = "ON"
        enabledButton.BackgroundColor3 = Color3.fromRGB(65, 65, 65)
    else
        enabledButton.Text = "OFF"
        enabledButton.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    end
end

enabledButton.MouseButton1Click:Connect(function()
    settings.enabled = not settings.enabled
    updateEnabled()
    notify(settings.enabled and "AI enabled." or "AI disabled.", "info")
end)

makeSlider(settingsScroll, "Speech Range", 276, 0, 500, settings.range, function(value)
    if value == 0 then
        return "0 — Infinite"
    end

    return tostring(value)
end, function(value)
    settings.range = value
end)

makeSlider(settingsScroll, "Request Cooldown", 336, 1, 30, settings.cooldown, function(value)
    return value .. "s"
end, function(value)
    settings.cooldown = value
end)

local clearButton = button(
    settingsScroll,
    "Clear Memory",
    UDim2.new(1, 0, 0, 32),
    UDim2.new(0, 0, 0, 392)
)

local saveButton = button(
    settingsScroll,
    "Save Configuration",
    UDim2.new(1, 0, 0, 32),
    UDim2.new(0, 0, 0, 430)
)

label(
    settingsScroll,
    "Persona Presets",
    UDim2.new(1, 0, 0, 16),
    UDim2.new(0, 0, 0, 476)
)

local PERSONA_PRESETS = {
    {name = "Friendly", prompt = "You are a warm, upbeat, friendly companion. Keep replies short and cheerful."},
    {name = "Sassy", prompt = "You are a witty, sarcastic companion who teases players playfully but never meanly."},
    {name = "Robot", prompt = "You are a formal, precise robotic assistant. Speak plainly and efficiently."},
    {name = "Pirate", prompt = "You are a swashbuckling pirate companion. Speak with pirate slang and flair."}
}

for index, preset in ipairs(PERSONA_PRESETS) do
    local presetButton = button(
        settingsScroll,
        preset.name,
        UDim2.new(0.24, -3, 0, 26),
        UDim2.new((index - 1) * 0.25, 0, 0, 494)
    )

    presetButton.MouseButton1Click:Connect(function()
        promptBox.Text = preset.prompt
        notify(preset.name .. " persona loaded — hit Save to apply.", "info")
    end)
end

label(
    settingsScroll,
    "Bot Name",
    UDim2.new(1, 0, 0, 16),
    UDim2.new(0, 0, 0, 528)
)

local botNameBox = textbox(
    settingsScroll,
    "Jordan",
    settings.botName,
    UDim2.new(1, 0, 0, 30),
    UDim2.new(0, 0, 0, 546)
)

label(
    settingsScroll,
    "Idle Gestures",
    UDim2.new(0.6, 0, 0, 22),
    UDim2.new(0, 0, 0, 590)
)

local idleGesturesButton = button(
    settingsScroll,
    "",
    UDim2.new(0, 64, 0, 26),
    UDim2.new(1, -64, 0, 588)
)

local function updateIdleGesturesButton()
    idleGesturesButton.Text = settings.idleGestures and "ON" or "OFF"
    idleGesturesButton.BackgroundColor3 = settings.idleGestures
        and Color3.fromRGB(65, 65, 65) or Color3.fromRGB(30, 30, 30)
end

idleGesturesButton.MouseButton1Click:Connect(function()
    settings.idleGestures = not settings.idleGestures
    updateIdleGesturesButton()
    saveSettings()
end)

updateIdleGesturesButton()

saveButton.MouseButton1Click:Connect(function()
    settings[settings.provider .. "Api"] = apiBox.Text
    settings[settings.provider .. "Model"] = modelBox.Text
    settings.prompt = promptBox.Text

    if botNameBox.Text ~= "" then
        settings.botName = botNameBox.Text
    end

    if settings[settings.provider .. "Api"] == "" then
        notify("Enter your " .. PROVIDERS[settings.provider].name .. " API key.", "error")
        return
    end

    if settings[settings.provider .. "Model"] == "" then
        notify("Enter a model name.", "error")
        return
    end

    if saveSettings() then
        notify("Configuration saved.", "success")
    else
        notify("Saved for this session only.", "info")
    end
end)

local creditsText = label(
    creditsPage,
    "Made by Jordan",
    UDim2.new(1, 0, 0, 44),
    UDim2.new(0, 0, 0.35, 0),
    18
)

creditsText.TextXAlignment = Enum.TextXAlignment.Center
creditsText.TextColor3 = Color3.fromRGB(210, 210, 210)
creditsText.Font = Enum.Font.GothamBold

local creditsSub = label(
    creditsPage,
    "AI Chatbot",
    UDim2.new(1, 0, 0, 24),
    UDim2.new(0, 0, 0.48, 0),
    11
)

creditsSub.TextXAlignment = Enum.TextXAlignment.Center

local pages = {
    chat = chatPage,
    settings = settingsPage,
    actions = actionsPage,
    admins = adminsPage,
    credits = creditsPage
}

local function showPage(pageName)
    for name, page in pairs(pages) do
        if name == pageName then
            page.Visible = true

            if page:IsA("CanvasGroup") then
                page.GroupTransparency = 1
                TweenService:Create(page, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                    GroupTransparency = 0
                }):Play()
            end
        else
            page.Visible = false
        end
    end
end

chatTab.MouseButton1Click:Connect(function()
    showPage("chat")
end)

settingsTab.MouseButton1Click:Connect(function()
    showPage("settings")
end)

actionsTab.MouseButton1Click:Connect(function()
    showPage("actions")
end)

adminsTab.MouseButton1Click:Connect(function()
    showPage("admins")
end)

creditsTab.MouseButton1Click:Connect(function()
    showPage("credits")
end)

local function getInventoryNames()
    local names = {}

    local backpack = player:FindFirstChild("Backpack")

    if backpack then
        for _, item in ipairs(backpack:GetChildren()) do
            if item:IsA("Tool") then
                table.insert(names, item.Name)
            end
        end
    end

    local character = player.Character

    if character then
        for _, item in ipairs(character:GetChildren()) do
            if item:IsA("Tool") then
                table.insert(names, item.Name .. " (equipped)")
            end
        end
    end

    return names
end

local ACCESSORY_TYPE_LABELS = {
    Hat = "hat", Hair = "hair", Face = "face accessory", Neck = "neck accessory",
    Shoulder = "shoulder accessory", Front = "front accessory", Back = "back accessory",
    Waist = "waist accessory", Eyebrow = "eyebrows", Eyelash = "eyelashes",
    TShirtAccessory = "t-shirt", ShirtAccessory = "shirt", PantsAccessory = "pants",
    JacketAccessory = "jacket", SweaterAccessory = "sweater", ShortsAccessory = "shorts",
    LeftShoeAccessory = "left shoe", RightShoeAccessory = "right shoe",
    DressSkirtAccessory = "dress/skirt"
}

local function getAvatarItems(targetPlayer)
    local character = targetPlayer and targetPlayer.Character
    local items = {}

    if not character then
        return items
    end

    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("Accessory") then
            local ok, accessoryType = pcall(function()
                return child.AccessoryType.Name
            end)

            local label = ok and ACCESSORY_TYPE_LABELS[accessoryType]
            table.insert(items, child.Name .. (label and (" (" .. label .. ")") or ""))
        elseif child:IsA("Shirt") then
            table.insert(items, "a shirt")
        elseif child:IsA("Pants") then
            table.insert(items, "pants")
        end
    end

    return items
end

local function buildSystemPrompt(speakerPlayer, speakerName)
    local tools = getInventoryNames()
    local toolsText = #tools > 0 and table.concat(tools, ", ") or "none"
    local gameText = GAME_NAME and (" You are currently in the Roblox game \"" .. GAME_NAME .. "\".") or ""

    local avatarItems = getAvatarItems(speakerPlayer)
    local avatarText = ""

    if #avatarItems > 0 then
        avatarText = " " .. speakerName .. " is currently wearing: " .. table.concat(avatarItems, ", ")
            .. " — you can mention or describe this if asked about their appearance, outfit, or what they're "
            .. "wearing."
    end

    return "You control this Roblox character named " .. settings.botName .. "." .. gameText .. " You are "
        .. "talking with " .. speakerName .. " (you may use their name)." .. avatarText .. " Current tools: "
        .. toolsText .. ". "
        .. "Judge intent from meaning, not exact wording: any phrasing of a genuine, direct, present request "
        .. "counts (commands, polite asks, questions like 'can you jump?'). Never tag from casual mentions, "
        .. "hypotheticals, or requests aimed at someone else ('I love dancing', 'tell him to sit' should not "
        .. "tag DANCE/SIT). "
        .. "If asked your tools, list them and ask which to equip; once told, reply briefly and add "
        .. "[ACTION:EQUIP:ExactToolName] (exact name from the list). If also asked to use/drink/eat/swing it, "
        .. "also add [ACTION:USE] right after. [ACTION:UNEQUIP] puts it away. [ACTION:DROP] drops the equipped "
        .. "item. "
        .. "[ACTION:JUMP] for one jump; for multiple, use ONE [ACTION:JUMP:N] tag with N as a digit (max 5) — "
        .. "'twice' means N=2 — never repeat separate JUMP tags. "
        .. "Gestures (pick exactly one that matches): [ACTION:WAVE] [ACTION:POINT] [ACTION:DANCE] "
        .. "[ACTION:DANCE2] [ACTION:DANCE3] (2/3 are alt dances) [ACTION:LAUGH] [ACTION:CHEER] [ACTION:BOW] "
        .. "[ACTION:NOD] [ACTION:SHAKEHEAD] [ACTION:SALUTE] [ACTION:FACEPALM] [ACTION:SHRUG] [ACTION:CROSSARMS] "
        .. "[ACTION:THUMBSUP] [ACTION:CLAP] [ACTION:SHIVER] [ACTION:HANDSUP] [ACTION:LOOKUP] [ACTION:LOOKDOWN] "
        .. "[ACTION:LOOKAROUND] (brief glance, returns; different from LOOKAT) [ACTION:TAPFOOT] "
        .. "[ACTION:TILTHEAD] [ACTION:WIGGLE] [ACTION:TPOSE] [ACTION:KNEEL] [ACTION:STOMP] [ACTION:SURPRISE] "
        .. "(random fun gesture, for 'do something fun/random') [ACTION:SHOWOFF] (a little jump+spin+cheer "
        .. "trick, for 'show off' or 'do a trick'). Most gestures accept an optional :N to repeat that gesture "
        .. "N times in a row (max 5), e.g. [ACTION:WAVE:3] waves three times, [ACTION:CLAP:2] claps twice — use "
        .. "this instead of repeating the same tag. "
        .. "[ACTION:SPIN] spins 5s by default, or [ACTION:SPIN:SECONDS] for a specific duration (max 15). "
        .. "[ACTION:SIT] / [ACTION:STANDUP]. [ACTION:SITONSEAT] sits in a real nearby "
        .. "seat if one exists. [ACTION:RESET] respawns the character (only if explicitly asked to reset/"
        .. "respawn). [ACTION:STOP] cancels a dance/spin/emote. "
        .. "[ACTION:MOVE:LEFT/RIGHT/FORWARD/BACK] brief nudge, or add :SECONDS for a longer move (max 5s), e.g. "
        .. "[ACTION:MOVE:LEFT:3]. [ACTION:SPRINT] ~3s speed boost. [ACTION:SNEAK] ~4s slowdown. "
        .. "[ACTION:TURNAROUND] quick 180, stays facing that way. [ACTION:CIRCLE] walks a loop. "
        .. "[ACTION:LOOKAT:ExactUsername] faces them. [ACTION:VISIT:ExactUsername] walks over once (max 10s, "
        .. "doesn't return). [ACTION:STAY] halts any movement. [ACTION:WANDER] walks to one random nearby spot. "
        .. "[ACTION:FLY] rises then hovers ~8s. [ACTION:LAND] stops flying. [ACTION:FLYFOLLOW:ExactUsername] "
        .. "flies to them up to 10s then flies back. "
        .. "[ACTION:HIT:ExactUsername] walks to them (drawing a weapon automatically if available), strikes "
        .. "once, then returns (max 10s each way); for multiple strikes use [ACTION:HIT:ExactUsername:N] (max "
        .. "5) — never repeat HIT tags. [ACTION:STOPATTACK] cancels. "
        .. "[ACTION:FOLLOW:ExactUsername] follows up to 10s then returns. [ACTION:STOPFOLLOW] cancels. "
        .. "[ACTION:HUG:ExactUsername] walks to them and gives a friendly hug gesture, then returns. "
        .. "For LOOKAT/VISIT/FOLLOW/FLYFOLLOW/HIT/HUG, use NEAREST or FURTHEST in place of a username when "
        .. "asked for the closest/farthest player. "
        .. "Only add a tag for something actually requested — never guess or add one nobody asked for. If one "
        .. "message genuinely asks for several things (e.g. 'wave then dance', 'jump twice and spin'), include "
        .. "a tag for each, in the order requested (up to 8 tags total per reply); actions run one after "
        .. "another, not simultaneously, so a slow one (HIT, FOLLOW, FLY) delays whatever's chained after it. "
        .. "Keep replies short."
end

local EMOTE_ANIMATION_IDS = {
    wave = "rbxassetid://507770239",
    point = "rbxassetid://507770453",
    dance = "rbxassetid://507771019",
    dance2 = "rbxassetid://507776043",
    dance3 = "rbxassetid://507777268",
    laugh = "rbxassetid://507770818",
    cheer = "rbxassetid://507770677"
}

local activeEmoteTrack = nil

local function stopEmote()
    if activeEmoteTrack then
        pcall(function()
            activeEmoteTrack:Stop()
        end)
        activeEmoteTrack = nil
    end
end

local function playEmote(name)
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if not humanoid then
        return
    end

    stopEmote()

    local animId = EMOTE_ANIMATION_IDS[name]

    if not animId then
        pcall(function()
            humanoid:PlayEmote(name)
        end)
        return
    end

    local animator = humanoid:FindFirstChildOfClass("Animator")

    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end

    local track

    pcall(function()
        local animation = Instance.new("Animation")
        animation.AnimationId = animId

        track = animator:LoadAnimation(animation)
        track.Looped = true
        track:Play()
        activeEmoteTrack = track
    end)

    if track then
        task.spawn(function()
            task.wait(5)

            if activeEmoteTrack == track then
                stopEmote()
            end
        end)
    end
end

local function findWeaponTool()
    local backpack = player:FindFirstChild("Backpack")

    if not backpack then
        return nil
    end

    for _, item in ipairs(backpack:GetChildren()) do
        if item:IsA("Tool") and item.Name:lower():find("sword", 1, true) then
            return item
        end
    end

    return nil
end

local function findPlayerByName(targetName)
    for _, other in ipairs(Players:GetPlayers()) do
        if other.Name:lower() == targetName:lower()
        or other.DisplayName:lower() == targetName:lower() then
            return other
        end
    end

    return nil
end

local NEAREST_WORDS = {nearest = true, closest = true}
local FURTHEST_WORDS = {furthest = true, farthest = true}

local function findByDistance(wantNearest)
    local rootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart")

    if not rootPart then
        return nil
    end

    local best = nil
    local bestDistance = nil

    for _, other in ipairs(Players:GetPlayers()) do
        if other ~= player then
            local otherRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart")

            if otherRoot then
                local distance = (rootPart.Position - otherRoot.Position).Magnitude

                if not bestDistance
                or (wantNearest and distance < bestDistance)
                or (not wantNearest and distance > bestDistance) then
                    best = other
                    bestDistance = distance
                end
            end
        end
    end

    return best
end

local function resolvePlayerTarget(name)
    if not name or name == "" then
        return nil
    end

    local lowered = name:lower():gsub("%s+player$", ""):gsub("%s+person$", "")

    if NEAREST_WORDS[lowered] then
        return findByDistance(true)
    end

    if FURTHEST_WORDS[lowered] then
        return findByDistance(false)
    end

    return findPlayerByName(name)
end

local function getAdminEntry(userId)
    for _, entry in ipairs(settings.admins) do
        if entry.userId == userId then
            return entry
        end
    end

    return nil
end

local function isOwner(userId)
    return userId == player.UserId
end

local function isAdmin(userId)
    return isOwner(userId) or getAdminEntry(userId) ~= nil
end

local function isBlacklisted(userId)
    for _, entry in ipairs(settings.blacklist) do
        if entry.userId == userId then
            return true
        end
    end

    return false
end

local function refreshAdminRows()
    for _, child in ipairs(adminRowsContainer:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end

    for index, entry in ipairs(settings.admins) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, 56)
        row.BackgroundColor3 = Color3.fromRGB(28, 28, 28)
        row.BorderSizePixel = 0
        row.LayoutOrder = index
        row.Parent = adminRowsContainer

        round(row, 6)

        label(row, entry.name, UDim2.new(1, -70, 0, 18), UDim2.new(0, 6, 0, 4))

        local providerToggle = button(
            row,
            entry.canChangeProvider and "Provider: ON" or "Provider: OFF",
            UDim2.new(0.48, -4, 0, 22),
            UDim2.new(0, 6, 0, 26)
        )

        local modelToggle = button(
            row,
            entry.canChangeModel and "Model: ON" or "Model: OFF",
            UDim2.new(0.48, -4, 0, 22),
            UDim2.new(0.5, 0, 0, 26)
        )

        local removeButton = button(
            row,
            "Remove",
            UDim2.new(0, 62, 0, 44),
            UDim2.new(1, -68, 0, 6)
        )

        providerToggle.MouseButton1Click:Connect(function()
            entry.canChangeProvider = not entry.canChangeProvider
            providerToggle.Text = entry.canChangeProvider and "Provider: ON" or "Provider: OFF"
            saveSettings()
        end)

        modelToggle.MouseButton1Click:Connect(function()
            entry.canChangeModel = not entry.canChangeModel
            modelToggle.Text = entry.canChangeModel and "Model: ON" or "Model: OFF"
            saveSettings()
        end)

        removeButton.MouseButton1Click:Connect(function()
            for i, e in ipairs(settings.admins) do
                if e.userId == entry.userId then
                    table.remove(settings.admins, i)
                    break
                end
            end

            saveSettings()
            refreshAdminRows()
            notify(entry.name .. " removed from admins.", "info")
        end)
    end
end

local function refreshBlacklistRows()
    for _, child in ipairs(blacklistRowsContainer:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end

    for index, entry in ipairs(settings.blacklist) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, 32)
        row.BackgroundColor3 = Color3.fromRGB(28, 28, 28)
        row.BorderSizePixel = 0
        row.LayoutOrder = index
        row.Parent = blacklistRowsContainer

        round(row, 6)

        label(row, entry.name, UDim2.new(1, -70, 1, 0), UDim2.new(0, 6, 0, 0))

        local removeButton = button(
            row,
            "Unblock",
            UDim2.new(0, 62, 0, 24),
            UDim2.new(1, -68, 0, 4)
        )

        removeButton.MouseButton1Click:Connect(function()
            for i, e in ipairs(settings.blacklist) do
                if e.userId == entry.userId then
                    table.remove(settings.blacklist, i)
                    break
                end
            end

            saveSettings()
            refreshBlacklistRows()
            notify(entry.name .. " removed from blacklist.", "info")
        end)
    end
end

grantAdminButton.MouseButton1Click:Connect(function()
    local name = adminNameBox.Text

    if name == "" then
        return
    end

    local targetPlayer = findPlayerByName(name)

    if not targetPlayer then
        notify("Player not found.", "error")
        return
    end

    if isOwner(targetPlayer.UserId) then
        notify(targetPlayer.Name .. " already has full owner access.", "info")
        return
    end

    if getAdminEntry(targetPlayer.UserId) then
        notify(targetPlayer.Name .. " is already an admin.", "info")
        return
    end

    table.insert(settings.admins, {
        userId = targetPlayer.UserId,
        name = targetPlayer.Name,
        canChangeProvider = true,
        canChangeModel = true,
        allowedModels = {}
    })

    saveSettings()
    refreshAdminRows()
    adminNameBox.Text = ""
    notify(targetPlayer.Name .. " is now an admin.", "success")
    speakInGameChat(targetPlayer.Name .. " is now admin!")
end)

blacklistAddButton.MouseButton1Click:Connect(function()
    local name = blacklistNameBox.Text

    if name == "" then
        return
    end

    local targetPlayer = findPlayerByName(name)

    if not targetPlayer then
        notify("Player not found.", "error")
        return
    end

    if isOwner(targetPlayer.UserId) then
        notify("You can't blacklist the owner.", "error")
        return
    end

    for _, entry in ipairs(settings.blacklist) do
        if entry.userId == targetPlayer.UserId then
            notify(targetPlayer.Name .. " is already blacklisted.", "info")
            return
        end
    end

    for i, entry in ipairs(settings.admins) do
        if entry.userId == targetPlayer.UserId then
            table.remove(settings.admins, i)
            break
        end
    end

    table.insert(settings.blacklist, {
        userId = targetPlayer.UserId,
        name = targetPlayer.Name
    })

    saveSettings()
    refreshAdminRows()
    refreshBlacklistRows()
    blacklistNameBox.Text = ""
    notify(targetPlayer.Name .. " blacklisted.", "success")
end)

refreshAdminRows()
refreshBlacklistRows()

local function checkUnstuck(character, humanoid, stuckState)
    local rootPart = character:FindFirstChild("HumanoidRootPart")

    if not rootPart then
        return
    end

    local now = os.clock()

    if not stuckState.lastPosition then
        stuckState.lastPosition = rootPart.Position
        stuckState.lastCheckTime = now
        return
    end

    if now - stuckState.lastCheckTime >= 1.5 then
        local moved = (rootPart.Position - stuckState.lastPosition).Magnitude

        if moved < 1.5 and humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
            humanoid.Jump = true
        end

        stuckState.lastPosition = rootPart.Position
        stuckState.lastCheckTime = now
    end
end

local function returnHome(humanoid, homePosition)
    if not humanoid or not homePosition then
        return
    end

    local startTime = os.clock()
    local stuckState = {}

    while os.clock() - startTime < 20 do
        local rootPart = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart")

        if not rootPart then
            return
        end

        if (rootPart.Position - homePosition).Magnitude <= 3 then
            return
        end

        checkUnstuck(humanoid.Parent, humanoid, stuckState)
        humanoid:MoveTo(homePosition)
        task.wait(1)
    end
end

local followToken = 0
local attackToken = 0
local flyToken = 0
local hitCounts = {}

local function stopFlying(character)
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    local bv = rootPart and rootPart:FindFirstChild("JordanAIFlight")

    if bv then
        bv:Destroy()
    end
end

local function startFlying(character)
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")

    if not rootPart then
        return nil
    end

    stopFlying(character)

    local bv = Instance.new("BodyVelocity")
    bv.Name = "JordanAIFlight"
    bv.MaxForce = Vector3.new(100000, 100000, 100000)
    bv.Velocity = Vector3.new(0, 0, 0)
    bv.Parent = rootPart

    return bv
end

local function getShoulders(character)
    local upperTorso = character:FindFirstChild("UpperTorso")

    if upperTorso then
        return upperTorso:FindFirstChild("LeftShoulder"), upperTorso:FindFirstChild("RightShoulder")
    end

    local torso = character:FindFirstChild("Torso")

    if torso then
        return torso:FindFirstChild("Left Shoulder"), torso:FindFirstChild("Right Shoulder")
    end

    return nil, nil
end

local function poseArms(character, leftAngle, rightAngle, duration)
    local leftShoulder, rightShoulder = getShoulders(character)

    if not leftShoulder and not rightShoulder then
        return
    end

    local leftOriginal = leftShoulder and leftShoulder.C0
    local rightOriginal = rightShoulder and rightShoulder.C0

    pcall(function()
        if leftShoulder and leftAngle then
            leftShoulder.C0 = leftOriginal * leftAngle
        end

        if rightShoulder and rightAngle then
            rightShoulder.C0 = rightOriginal * rightAngle
        end
    end)

    task.wait(duration)

    pcall(function()
        if leftShoulder then
            leftShoulder.C0 = leftOriginal
        end

        if rightShoulder then
            rightShoulder.C0 = rightOriginal
        end
    end)
end

local function turnTo(character, original, fromAngle, toAngle, duration)
    local elapsed = 0

    while elapsed < duration do
        local dt = task.wait()
        elapsed += dt

        local currentRoot = character:FindFirstChild("HumanoidRootPart")

        if not currentRoot then
            return false
        end

        local progress = math.min(elapsed / duration, 1)
        local angle = fromAngle + (toAngle - fromAngle) * progress

        currentRoot.CFrame = original * CFrame.Angles(0, angle, 0)
    end

    return true
end

local function getHip(character, side)
    local lowerTorso = character:FindFirstChild("LowerTorso")

    if lowerTorso then
        return lowerTorso:FindFirstChild(side .. "Hip")
    end

    local torso = character:FindFirstChild("Torso")

    if torso then
        return torso:FindFirstChild(side .. " Hip")
    end

    return nil
end

local WORD_NUMBERS = {
    once = 1, one = 1,
    twice = 2, two = 2, couple = 2,
    thrice = 3, three = 3,
    four = 4,
    five = 5
}

local function parseCount(param)
    if not param or param == "" then
        return 1
    end

    local trimmed = param:match("^%s*(.-)%s*$")
    local num = tonumber(trimmed)

    if num then
        return num
    end

    local lowered = trimmed:lower()

    if WORD_NUMBERS[lowered] then
        return WORD_NUMBERS[lowered]
    end

    local digits = lowered:match("(%d+)")

    if digits then
        return tonumber(digits)
    end

    for word, value in pairs(WORD_NUMBERS) do
        if lowered:find("%f[%a]" .. word .. "%f[%A]") then
            return value
        end
    end

    return 1
end

local MAX_HITS_PER_TARGET = 50

local ACTIONS = {
    jump = function(param)
        local count = math.clamp(math.floor(parseCount(param)), 1, 5)
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")

        if not humanoid then
            return
        end

        for i = 1, count do
            humanoid.Jump = true

            local waited = 0

            while waited < 0.5
            and humanoid:GetState() ~= Enum.HumanoidStateType.Jumping
            and humanoid:GetState() ~= Enum.HumanoidStateType.Freefall do
                waited += task.wait(0.05)
            end

            waited = 0

            while waited < 2 and humanoid:GetState() ~= Enum.HumanoidStateType.Running do
                waited += task.wait(0.05)
            end

            if i < count then
                task.wait(0.15)
            end
        end
    end,

    wave = function()
        playEmote("wave")
    end,

    dance = function()
        playEmote("dance")
    end,

    dance2 = function()
        playEmote("dance2")
    end,

    dance3 = function()
        playEmote("dance3")
    end,

    laugh = function()
        playEmote("laugh")
    end,

    cheer = function()
        playEmote("cheer")
    end,

    point = function()
        playEmote("point")
    end,

    equip = function(toolName)
        if not toolName or toolName == "" then
            return
        end

        local backpack = player:FindFirstChild("Backpack")
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")

        if not backpack or not humanoid then
            return
        end

        for _, item in ipairs(backpack:GetChildren()) do
            if item:IsA("Tool") and item.Name:lower() == toolName:lower() then
                humanoid:EquipTool(item)
                break
            end
        end
    end,

    unequip = function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")

        if humanoid then
            humanoid:UnequipTools()
        end
    end,

    stop = function()
        stopEmote()
    end,

    spin = function(param)
        local duration = math.clamp(tonumber(param) or 5, 1, 15)
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        local previousAutoRotate = humanoid.AutoRotate
        humanoid.AutoRotate = false

        local elapsed = 0
        local rotationSpeed = math.rad(360)

        while elapsed < duration do
            local dt = task.wait()
            elapsed += dt

            local currentRoot = character:FindFirstChild("HumanoidRootPart")

            if not currentRoot then
                break
            end

            currentRoot.CFrame = currentRoot.CFrame * CFrame.Angles(0, rotationSpeed * dt, 0)
        end

        humanoid.AutoRotate = previousAutoRotate
    end,

    sit = function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")

        if humanoid then
            humanoid.Sit = true
        end
    end,

    use = function()
        local character = player.Character
        local tool = character and character:FindFirstChildOfClass("Tool")

        if not tool then
            return
        end

        pcall(function()
            tool:Activate()
        end)
    end,

    hit = function(param)
        if not param or param == "" then
            return
        end

        local targetName, countStr = param:match("^(.-):(%d+)$")

        if not targetName or targetName == "" then
            targetName = param
        end

        local strikeCount = math.clamp(math.floor(tonumber(countStr) or 1), 1, 5)

        local targetPlayer = resolvePlayerTarget(targetName)

        if not targetPlayer then
            return
        end

        if (hitCounts[targetPlayer.UserId] or 0) >= MAX_HITS_PER_TARGET then
            return
        end

        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        local homePosition = rootPart.Position

        attackToken += 1
        local myToken = attackToken

        local startTime = os.clock()
        local reached = false
        local stuckState = {}

        while myToken == attackToken and os.clock() - startTime < 20 do
            local targetChar = targetPlayer.Character
            local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
            local currentRoot = character:FindFirstChild("HumanoidRootPart")

            if not targetRoot or not currentRoot or not targetPlayer.Parent then
                break
            end

            if (currentRoot.Position - targetRoot.Position).Magnitude <= 5 then
                reached = true
                break
            end

            checkUnstuck(character, humanoid, stuckState)
            humanoid:MoveTo(targetRoot.Position)
            task.wait(1)
        end

        if reached and myToken == attackToken then
            local tool = character:FindFirstChildOfClass("Tool")

            if not tool then
                local weapon = findWeaponTool()

                if weapon then
                    humanoid:EquipTool(weapon)
                    task.wait(0.2)
                    tool = character:FindFirstChildOfClass("Tool")
                end
            end

            if tool then
                for strike = 1, strikeCount do
                    if myToken ~= attackToken then
                        break
                    end

                    if (hitCounts[targetPlayer.UserId] or 0) >= MAX_HITS_PER_TARGET then
                        break
                    end

                    pcall(function()
                        tool:Activate()
                    end)

                    hitCounts[targetPlayer.UserId] = (hitCounts[targetPlayer.UserId] or 0) + 1

                    if strike < strikeCount then
                        task.wait(0.5)
                    end
                end

                if myToken == attackToken then
                    pcall(function()
                        humanoid:UnequipTools()
                    end)
                end
            end
        end

        returnHome(humanoid, homePosition)
    end,

    stopattack = function()
        attackToken += 1
    end,

    follow = function(targetName)
        if not targetName or targetName == "" then
            return
        end

        local targetPlayer = resolvePlayerTarget(targetName)

        if not targetPlayer then
            return
        end

        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        local homePosition = rootPart.Position

        followToken += 1
        local myToken = followToken

        local startTime = os.clock()
        local stuckState = {}

        while myToken == followToken and os.clock() - startTime < 20 do
            local targetChar = targetPlayer.Character
            local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
            local currentRoot = character:FindFirstChild("HumanoidRootPart")

            if not targetRoot or not currentRoot or not targetPlayer.Parent then
                break
            end

            if (currentRoot.Position - targetRoot.Position).Magnitude > 5 then
                checkUnstuck(character, humanoid, stuckState)
                humanoid:MoveTo(targetRoot.Position)
            end

            task.wait(0.5)
        end

        returnHome(humanoid, homePosition)
    end,

    stopfollow = function()
        followToken += 1
    end,

    move = function(param)
        if not param or param == "" then
            return
        end

        local direction, secondsStr = param:match("^(%a+):?([%d%.]*)$")

        if not direction then
            direction = param
        end

        local duration = math.clamp(tonumber(secondsStr) or 0.8, 0.3, 5)

        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        local directions = {
            left = -rootPart.CFrame.RightVector,
            right = rootPart.CFrame.RightVector,
            forward = rootPart.CFrame.LookVector,
            forwards = rootPart.CFrame.LookVector,
            back = -rootPart.CFrame.LookVector,
            backward = -rootPart.CFrame.LookVector,
            backwards = -rootPart.CFrame.LookVector
        }

        local vector = directions[direction:lower()]

        if not vector then
            return
        end

        humanoid:Move(vector, false)
        task.wait(duration)
        humanoid:Move(Vector3.new(0, 0, 0), false)
    end,

    stay = function()
        followToken += 1
        attackToken += 1

        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if humanoid and rootPart then
            humanoid:MoveTo(rootPart.Position)
        end
    end,

    visit = function(targetName)
        if not targetName or targetName == "" then
            return
        end

        local targetPlayer = resolvePlayerTarget(targetName)

        if not targetPlayer then
            return
        end

        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        local startTime = os.clock()

        while os.clock() - startTime < 10 do
            local targetChar = targetPlayer.Character
            local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
            local currentRoot = character:FindFirstChild("HumanoidRootPart")

            if not targetRoot or not currentRoot or not targetPlayer.Parent then
                return
            end

            if (currentRoot.Position - targetRoot.Position).Magnitude <= 5 then
                return
            end

            humanoid:MoveTo(targetRoot.Position)
            task.wait(1)
        end
    end,

    lookat = function(targetName)
        if not targetName or targetName == "" then
            return
        end

        local targetPlayer = resolvePlayerTarget(targetName)

        if not targetPlayer then
            return
        end

        local character = player.Character
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")
        local targetChar = targetPlayer.Character
        local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")

        if not rootPart or not targetRoot then
            return
        end

        local lookPosition = Vector3.new(targetRoot.Position.X, rootPart.Position.Y, targetRoot.Position.Z)
        rootPart.CFrame = CFrame.lookAt(rootPart.Position, lookPosition)
    end,

    bow = function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")

        if not humanoid then
            return
        end

        local previousAutoRotate = humanoid.AutoRotate
        humanoid.AutoRotate = false

        local originalCFrame = character.HumanoidRootPart and character.HumanoidRootPart.CFrame

        if not originalCFrame then
            humanoid.AutoRotate = previousAutoRotate
            return
        end

        local elapsed = 0
        local duration = 1.6

        while elapsed < duration do
            local dt = task.wait()
            elapsed += dt

            local currentRoot = character:FindFirstChild("HumanoidRootPart")

            if not currentRoot then
                break
            end

            local progress = elapsed / duration
            local angle

            if progress < 0.5 then
                angle = math.rad(35) * (progress / 0.5)
            else
                angle = math.rad(35) * (1 - (progress - 0.5) / 0.5)
            end

            currentRoot.CFrame = originalCFrame * CFrame.Angles(angle, 0, 0)
        end

        local finalRoot = character:FindFirstChild("HumanoidRootPart")

        if finalRoot then
            finalRoot.CFrame = originalCFrame
        end

        humanoid.AutoRotate = previousAutoRotate
    end,

    nod = function()
        local character = player.Character

        if not character then
            return
        end

        local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
        local neck = torso and torso:FindFirstChild("Neck")

        if not neck then
            return
        end

        local originalC0 = neck.C0
        local elapsed = 0
        local duration = 1

        while elapsed < duration do
            local dt = task.wait()
            elapsed += dt

            local wobble = math.sin(elapsed * math.pi * 4) * math.rad(20)
            neck.C0 = originalC0 * CFrame.Angles(wobble, 0, 0)
        end

        neck.C0 = originalC0
    end,

    shakehead = function()
        local character = player.Character

        if not character then
            return
        end

        local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
        local neck = torso and torso:FindFirstChild("Neck")

        if not neck then
            return
        end

        local originalC0 = neck.C0
        local elapsed = 0
        local duration = 1

        while elapsed < duration do
            local dt = task.wait()
            elapsed += dt

            local wobble = math.sin(elapsed * math.pi * 4) * math.rad(25)
            neck.C0 = originalC0 * CFrame.Angles(0, wobble, 0)
        end

        neck.C0 = originalC0
    end,

    fly = function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        flyToken += 1
        local myToken = flyToken

        local bv = startFlying(character)

        if not bv then
            return
        end

        local elapsed = 0
        local duration = 8

        while myToken == flyToken and elapsed < duration do
            local dt = task.wait()
            elapsed += dt

            local currentRoot = character:FindFirstChild("HumanoidRootPart")
            local currentBv = currentRoot and currentRoot:FindFirstChild("JordanAIFlight")

            if not currentRoot or not currentBv then
                break
            end

            if elapsed < 1 then
                currentBv.Velocity = Vector3.new(0, 6, 0)
            else
                currentBv.Velocity = Vector3.new(0, 0, 0)
            end
        end

        if myToken == flyToken then
            stopFlying(character)
        end
    end,

    land = function()
        flyToken += 1
        stopFlying(player.Character)
    end,

    flyfollow = function(targetName)
        if not targetName or targetName == "" then
            return
        end

        local targetPlayer = resolvePlayerTarget(targetName)

        if not targetPlayer then
            return
        end

        local character = player.Character
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not rootPart then
            return
        end

        local homePosition = rootPart.Position

        flyToken += 1
        local myToken = flyToken

        local bv = startFlying(character)

        if not bv then
            return
        end

        local startTime = os.clock()

        while myToken == flyToken and os.clock() - startTime < 10 do
            local targetChar = targetPlayer.Character
            local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
            local currentRoot = character:FindFirstChild("HumanoidRootPart")
            local currentBv = currentRoot and currentRoot:FindFirstChild("JordanAIFlight")

            if not targetRoot or not currentRoot or not currentBv or not targetPlayer.Parent then
                break
            end

            local offset = targetRoot.Position - currentRoot.Position
            local distance = offset.Magnitude

            if distance > 5 then
                currentBv.Velocity = offset.Unit * 40
            else
                currentBv.Velocity = Vector3.new(0, 0, 0)
            end

            task.wait(0.2)
        end

        local flyBackStart = os.clock()

        while myToken == flyToken and os.clock() - flyBackStart < 10 do
            local currentRoot = character:FindFirstChild("HumanoidRootPart")
            local currentBv = currentRoot and currentRoot:FindFirstChild("JordanAIFlight")

            if not currentRoot or not currentBv then
                break
            end

            local offset = homePosition - currentRoot.Position

            if offset.Magnitude <= 3 then
                break
            end

            currentBv.Velocity = offset.Unit * 40
            task.wait(0.2)
        end

        if myToken == flyToken then
            stopFlying(character)
        end
    end,

    salute = function()
        local character = player.Character

        if character then
            poseArms(character, nil, CFrame.Angles(0, 0, math.rad(-150)), 1.4)
        end
    end,

    facepalm = function()
        local character = player.Character

        if character then
            poseArms(character, nil, CFrame.Angles(math.rad(-120), 0, math.rad(30)), 1.5)
        end
    end,

    shrug = function()
        local character = player.Character

        if character then
            poseArms(character, CFrame.Angles(0, 0, math.rad(20)), CFrame.Angles(0, 0, math.rad(-20)), 1)
        end
    end,

    crossarms = function()
        local character = player.Character

        if character then
            poseArms(character, CFrame.Angles(0, 0, math.rad(-100)), CFrame.Angles(0, 0, math.rad(100)), 2)
        end
    end,

    thumbsup = function()
        local character = player.Character

        if character then
            poseArms(character, nil, CFrame.Angles(math.rad(-90), 0, 0), 1.5)
        end
    end,

    clap = function()
        local character = player.Character

        if not character then
            return
        end

        local leftShoulder, rightShoulder = getShoulders(character)

        if not leftShoulder or not rightShoulder then
            return
        end

        local leftOriginal = leftShoulder.C0
        local rightOriginal = rightShoulder.C0
        local elapsed = 0
        local duration = 1.4

        while elapsed < duration do
            local dt = task.wait()
            elapsed += dt

            local wobble = (math.sin(elapsed * math.pi * 6) + 1) / 2

            pcall(function()
                leftShoulder.C0 = leftOriginal * CFrame.Angles(0, 0, math.rad(-60) * wobble)
                rightShoulder.C0 = rightOriginal * CFrame.Angles(0, 0, math.rad(60) * wobble)
            end)
        end

        pcall(function()
            leftShoulder.C0 = leftOriginal
            rightShoulder.C0 = rightOriginal
        end)
    end,

    shiver = function()
        local character = player.Character
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not rootPart then
            return
        end

        local original = rootPart.CFrame
        local elapsed = 0
        local duration = 1

        while elapsed < duration do
            local dt = task.wait()
            elapsed += dt

            local currentRoot = character:FindFirstChild("HumanoidRootPart")

            if not currentRoot then
                break
            end

            local jitter = math.sin(elapsed * math.pi * 20) * math.rad(4)
            currentRoot.CFrame = original * CFrame.Angles(0, 0, jitter)
        end

        local finalRoot = character:FindFirstChild("HumanoidRootPart")

        if finalRoot then
            finalRoot.CFrame = original
        end
    end,

    standup = function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")

        if humanoid then
            humanoid.Sit = false
        end
    end,

    lookaround = function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        local previousAutoRotate = humanoid.AutoRotate
        humanoid.AutoRotate = false

        local original = rootPart.CFrame

        if turnTo(character, original, 0, math.rad(50), 0.6) then
            task.wait(0.3)

            if turnTo(character, original, math.rad(50), math.rad(-50), 1.0) then
                task.wait(0.3)
                turnTo(character, original, math.rad(-50), 0, 0.6)
            end
        end

        local finalRoot = character:FindFirstChild("HumanoidRootPart")

        if finalRoot then
            finalRoot.CFrame = original
        end

        humanoid.AutoRotate = previousAutoRotate
    end,

    lookup = function()
        local character = player.Character

        if not character then
            return
        end

        local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
        local neck = torso and torso:FindFirstChild("Neck")

        if not neck then
            return
        end

        local original = neck.C0

        pcall(function()
            neck.C0 = original * CFrame.Angles(math.rad(-25), 0, 0)
        end)

        task.wait(1.4)

        pcall(function()
            neck.C0 = original
        end)
    end,

    lookdown = function()
        local character = player.Character

        if not character then
            return
        end

        local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
        local neck = torso and torso:FindFirstChild("Neck")

        if not neck then
            return
        end

        local original = neck.C0

        pcall(function()
            neck.C0 = original * CFrame.Angles(math.rad(25), 0, 0)
        end)

        task.wait(1.4)

        pcall(function()
            neck.C0 = original
        end)
    end,

    handsup = function()
        local character = player.Character

        if character then
            poseArms(character, CFrame.Angles(0, 0, math.rad(170)), CFrame.Angles(0, 0, math.rad(-170)), 1.6)
        end
    end,

    drop = function()
        local character = player.Character
        local tool = character and character:FindFirstChildOfClass("Tool")

        if not tool then
            return
        end

        local handle = tool:FindFirstChild("Handle")
        local rootPart = character:FindFirstChild("HumanoidRootPart")

        pcall(function()
            tool.Parent = workspace
        end)

        if handle and rootPart then
            pcall(function()
                handle.CFrame = rootPart.CFrame * CFrame.new(0, -2, -2)
            end)
        end
    end,

    tapfoot = function()
        local character = player.Character

        if not character then
            return
        end

        local hip = getHip(character, "Right")

        if not hip then
            return
        end

        local original = hip.C0
        local elapsed = 0
        local duration = 1.5

        while elapsed < duration do
            local dt = task.wait()
            elapsed += dt

            local wobble = (math.sin(elapsed * math.pi * 5) + 1) / 2

            pcall(function()
                hip.C0 = original * CFrame.Angles(math.rad(-25) * wobble, 0, 0)
            end)
        end

        pcall(function()
            hip.C0 = original
        end)
    end,

    wander = function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        local angle = math.random() * math.pi * 2
        local distance = 8 + math.random() * 7
        local offset = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
        local target = rootPart.Position + offset

        humanoid:MoveTo(target)
        task.wait(6)
    end,

    sprint = function()
        local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")

        if not humanoid then
            return
        end

        local originalSpeed = humanoid.WalkSpeed
        humanoid.WalkSpeed = originalSpeed * 2

        task.wait(3)

        local currentHumanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")

        if currentHumanoid then
            currentHumanoid.WalkSpeed = originalSpeed
        end
    end,

    sneak = function()
        local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")

        if not humanoid then
            return
        end

        local originalSpeed = humanoid.WalkSpeed
        humanoid.WalkSpeed = math.max(originalSpeed * 0.4, 4)

        task.wait(4)

        local currentHumanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")

        if currentHumanoid then
            currentHumanoid.WalkSpeed = originalSpeed
        end
    end,

    turnaround = function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        local previousAutoRotate = humanoid.AutoRotate
        humanoid.AutoRotate = false

        local original = rootPart.CFrame
        turnTo(character, original, 0, math.pi, 0.6)

        humanoid.AutoRotate = previousAutoRotate
    end,

    tpose = function()
        local character = player.Character

        if character then
            poseArms(character, CFrame.Angles(0, 0, math.rad(90)), CFrame.Angles(0, 0, math.rad(-90)), 2)
        end
    end,

    tilthead = function()
        local character = player.Character

        if not character then
            return
        end

        local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
        local neck = torso and torso:FindFirstChild("Neck")

        if not neck then
            return
        end

        local original = neck.C0

        pcall(function()
            neck.C0 = original * CFrame.Angles(0, 0, math.rad(25))
        end)

        task.wait(1.4)

        pcall(function()
            neck.C0 = original
        end)
    end,

    wiggle = function()
        local character = player.Character
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not rootPart then
            return
        end

        local original = rootPart.CFrame
        local elapsed = 0
        local duration = 1.2

        while elapsed < duration do
            local dt = task.wait()
            elapsed += dt

            local currentRoot = character:FindFirstChild("HumanoidRootPart")

            if not currentRoot then
                break
            end

            local wobble = math.sin(elapsed * math.pi * 4) * math.rad(12)
            currentRoot.CFrame = original * CFrame.Angles(0, 0, wobble)
        end

        local finalRoot = character:FindFirstChild("HumanoidRootPart")

        if finalRoot then
            finalRoot.CFrame = original
        end
    end,

    circle = function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        local center = rootPart.Position
        local radius = 6
        local steps = 8

        for i = 1, steps do
            local angle = (i / steps) * math.pi * 2
            local target = center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)

            humanoid:MoveTo(target)
            task.wait(2)
        end
    end,

    reset = function()
        local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")

        if humanoid then
            humanoid.Health = 0
        end
    end,

    kneel = function()
        local character = player.Character

        if not character then
            return
        end

        local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
        local waist = torso and torso:FindFirstChild("Waist")

        if not waist then
            return
        end

        local original = waist.C0

        pcall(function()
            waist.C0 = original * CFrame.Angles(math.rad(55), 0, 0)
        end)

        task.wait(2)

        pcall(function()
            waist.C0 = original
        end)
    end,

    sitonseat = function()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        local nearestSeat = nil
        local nearestDistance = 15

        for _, descendant in ipairs(workspace:GetDescendants()) do
            if (descendant:IsA("Seat") or descendant:IsA("VehicleSeat")) and not descendant.Occupant then
                local ok, distance = pcall(function()
                    return (descendant.Position - rootPart.Position).Magnitude
                end)

                if ok and distance <= nearestDistance then
                    nearestSeat = descendant
                    nearestDistance = distance
                end
            end
        end

        if nearestSeat then
            pcall(function()
                nearestSeat:Sit(humanoid)
            end)
        end
    end,

    hug = function(targetName)
        if not targetName or targetName == "" then
            return
        end

        local targetPlayer = resolvePlayerTarget(targetName)

        if not targetPlayer then
            return
        end

        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rootPart = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not rootPart then
            return
        end

        local homePosition = rootPart.Position

        attackToken += 1
        local myToken = attackToken

        local startTime = os.clock()
        local reached = false

        while myToken == attackToken and os.clock() - startTime < 10 do
            local targetChar = targetPlayer.Character
            local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
            local currentRoot = character:FindFirstChild("HumanoidRootPart")

            if not targetRoot or not currentRoot or not targetPlayer.Parent then
                break
            end

            if (currentRoot.Position - targetRoot.Position).Magnitude <= 4 then
                reached = true
                break
            end

            humanoid:MoveTo(targetRoot.Position)
            task.wait(1)
        end

        if reached and myToken == attackToken then
            poseArms(character, CFrame.Angles(0, 0, math.rad(60)), CFrame.Angles(0, 0, math.rad(-60)), 1.2)
        end

        returnHome(humanoid, homePosition)
    end,

    stomp = function()
        local character = player.Character

        if not character then
            return
        end

        local hip = getHip(character, "Right")

        if not hip then
            return
        end

        local original = hip.C0

        pcall(function()
            hip.C0 = original * CFrame.Angles(math.rad(-35), 0, 0)
        end)

        task.wait(0.3)

        pcall(function()
            hip.C0 = original
        end)
    end
}

ACTIONS.surprise = function()
    local pool = {"wave", "dance", "cheer", "spin", "tpose", "wiggle", "handsup"}
    local pick = pool[math.random(1, #pool)]
    local actionFn = ACTIONS[pick]

    if actionFn and not settings.disabledActions[pick] then
        actionFn()
    end
end

ACTIONS.showoff = function()
    local jumpFn = ACTIONS.jump
    local spinFn = ACTIONS.spin
    local cheerFn = ACTIONS.cheer

    if jumpFn and not settings.disabledActions.jump then
        jumpFn("2")
    end

    if spinFn and not settings.disabledActions.spin then
        spinFn()
    end

    if cheerFn and not settings.disabledActions.cheer then
        cheerFn()
    end
end

local function withRepeat(actionFn, maxRepeats)
    return function(param)
        local count = math.clamp(math.floor(parseCount(param)), 1, maxRepeats or 5)

        for i = 1, count do
            actionFn()

            if i < count then
                task.wait(0.2)
            end
        end
    end
end

local REPEATABLE_GESTURES = {
    "wave", "dance", "dance2", "dance3", "laugh", "cheer", "bow", "nod",
    "shakehead", "salute", "facepalm", "shrug", "crossarms", "thumbsup",
    "clap", "shiver", "handsup", "lookup", "lookdown", "tapfoot", "tilthead",
    "wiggle", "tpose", "stomp", "kneel"
}

for _, gestureName in ipairs(REPEATABLE_GESTURES) do
    local originalFn = ACTIONS[gestureName]

    if originalFn then
        ACTIONS[gestureName] = withRepeat(originalFn, 5)
    end
end

local ACTION_ORDER = {
    "jump", "wave", "point", "dance", "dance2", "dance3", "laugh", "cheer",
    "bow", "nod", "shakehead", "salute", "facepalm", "shrug", "crossarms",
    "thumbsup", "clap", "shiver", "handsup", "lookup", "lookdown", "lookaround",
    "tapfoot", "tilthead", "wiggle", "tpose", "kneel", "surprise", "showoff", "stomp",
    "spin", "sit", "standup", "sitonseat", "stop", "reset",
    "equip", "unequip", "use", "drop",
    "move", "stay", "visit", "lookat", "follow", "stopfollow", "wander", "circle",
    "sprint", "sneak", "turnaround",
    "fly", "land", "flyfollow",
    "hit", "stopattack", "hug"
}

local ACTION_LABELS = {
    jump = "Jump", wave = "Wave", point = "Point", dance = "Dance",
    dance2 = "Dance 2", dance3 = "Dance 3", laugh = "Laugh", cheer = "Cheer",
    bow = "Bow", nod = "Nod", shakehead = "Shake Head", salute = "Salute",
    facepalm = "Facepalm", shrug = "Shrug", crossarms = "Cross Arms",
    thumbsup = "Thumbs Up", clap = "Clap", shiver = "Shiver", handsup = "Hands Up",
    lookup = "Look Up", lookdown = "Look Down", lookaround = "Look Around",
    tapfoot = "Tap Foot", tilthead = "Tilt Head", wiggle = "Wiggle", tpose = "T-Pose",
    kneel = "Kneel", surprise = "Surprise Me", showoff = "Show Off", stomp = "Stomp",
    spin = "Spin", sit = "Sit", standup = "Stand Up", sitonseat = "Sit In Seat",
    stop = "Stop Emote", reset = "Reset / Respawn", equip = "Equip Item",
    unequip = "Unequip Item", use = "Use Item", drop = "Drop Item", move = "Move",
    stay = "Stay / Halt", visit = "Walk To Player", lookat = "Look At Player",
    follow = "Follow Player", stopfollow = "Stop Following", wander = "Wander",
    circle = "Walk In Circle", sprint = "Sprint", sneak = "Sneak",
    turnaround = "Turn Around", fly = "Fly", land = "Land", flyfollow = "Fly Follow",
    hit = "Attack Player", stopattack = "Stop Attacking", hug = "Hug Player"
}

local actionRowRefreshers = {}

local function createActionToggleRow(actionName)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 28)
    row.BackgroundTransparency = 1
    row.Parent = actionsScroll

    label(row, ACTION_LABELS[actionName] or actionName, UDim2.new(1, -66, 1, 0), UDim2.new(0, 2, 0, 0))

    local toggle = button(row, "", UDim2.new(0, 58, 0, 24), UDim2.new(1, -58, 0, 2))

    local function refresh()
        if settings.disabledActions[actionName] then
            toggle.Text = "OFF"
            toggle.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
        else
            toggle.Text = "ON"
            toggle.BackgroundColor3 = Color3.fromRGB(65, 65, 65)
        end
    end

    toggle.MouseButton1Click:Connect(function()
        if settings.disabledActions[actionName] then
            settings.disabledActions[actionName] = nil
        else
            settings.disabledActions[actionName] = true
        end

        refresh()
        saveSettings()
    end)

    refresh()
    table.insert(actionRowRefreshers, refresh)
end

for _, actionName in ipairs(ACTION_ORDER) do
    createActionToggleRow(actionName)
end

enableAllButton.MouseButton1Click:Connect(function()
    settings.disabledActions = {}

    for _, refresh in ipairs(actionRowRefreshers) do
        refresh()
    end

    saveSettings()
    notify("All actions approved.", "success")
end)

disableAllButton.MouseButton1Click:Connect(function()
    for _, actionName in ipairs(ACTION_ORDER) do
        settings.disabledActions[actionName] = true
    end

    for _, refresh in ipairs(actionRowRefreshers) do
        refresh()
    end

    saveSettings()
    notify("All actions disabled.", "info")
end)

local MAX_ACTIONS_PER_REPLY = 8

local actionQueue = {}
local actionWorkerRunning = false

local function processActionQueue()
    if actionWorkerRunning then
        return
    end

    actionWorkerRunning = true

    while #actionQueue > 0 do
        local action = table.remove(actionQueue, 1)
        local ok, err = pcall(ACTIONS[action.name], action.param)

        if not ok then
            warn("JordanAI action '" .. action.name .. "' errored: " .. tostring(err))
        end
    end

    actionWorkerRunning = false
end

local function enqueueActions(actions, clearFirst)
    if clearFirst then
        table.clear(actionQueue)
    end

    for _, action in ipairs(actions) do
        table.insert(actionQueue, action)
    end

    task.spawn(processActionQueue)
end

local function runActions(actions)
    enqueueActions(actions, true)
end

local function processReply(rawText)
    local triggered = {}

    local cleaned = rawText:gsub(
        "%[%s*[Aa][Cc][Tt][Ii][Oo][Nn]%s*:%s*([%w_]+)%s*:?%s*([^%]]*)%]",
        function(name, param)
            table.insert(triggered, {name = name:lower(), param = param:match("^%s*(.-)%s*$")})
            return ""
        end
    )

    cleaned = cleaned:gsub("%[%s*[Aa][Cc][Tt][Ii][Oo][Nn][^%]]*%]?", "")
    cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s%s+", " ")

    local runnable = {}

    for _, action in ipairs(triggered) do
        if #runnable >= MAX_ACTIONS_PER_REPLY then
            break
        end

        if ACTIONS[action.name] and not settings.disabledActions[action.name] then
            table.insert(runnable, action)
        end
    end

    if #runnable > 0 then
        task.spawn(function()
            runActions(runnable)
        end)
    end

    if cleaned == "" and #triggered > 0 then
        cleaned = "*" .. triggered[1].name .. "*"
    end

    return cleaned
end

local function stripThinkingTags(text)
    text = text:gsub("<think>.-</think>", "")
    text = text:gsub("<thinking>.-</thinking>", "")
    text = text:gsub("<reasoning>.-</reasoning>", "")
    text = text:match("^%s*(.-)%s*$")

    return text
end

local function requestCompletion(provider, apiKey, model, messages)
    local req = getRequest()

    if not req then
        return false, "This environment does not provide an HTTP request function.", nil
    end

    local payload = {
        model = model,
        messages = messages,
        max_tokens = MAX_REPLY_TOKENS
    }

    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. apiKey
    }

    if settings.provider == "openrouter" then
        headers["HTTP-Referer"] = "https://www.roblox.com"
        headers["X-Title"] = "JordanAI"
    end

    local ok, response = pcall(function()
        return req({
            Url = provider.url,
            Method = "POST",
            Headers = headers,
            Body = HttpService:JSONEncode(payload)
        })
    end)

    if not ok then
        return false, "Request failed.", nil
    end

    if not response then
        return false, "No response was returned.", nil
    end

    if response.StatusCode < 200 or response.StatusCode >= 300 then
        local message = provider.name .. " request failed."

        local decodeOk, data = pcall(function()
            return HttpService:JSONDecode(response.Body)
        end)

        if decodeOk
        and type(data) == "table"
        and data.error
        and data.error.message then
            message = tostring(data.error.message)
        end

        return false, message, response.StatusCode
    end

    local decodedOk, data = pcall(function()
        return HttpService:JSONDecode(response.Body)
    end)

    if not decodedOk or type(data) ~= "table" then
        return false, "Invalid response from " .. provider.name .. ".", response.StatusCode
    end

    local answer = data
        and data.choices
        and data.choices[1]
        and data.choices[1].message
        and data.choices[1].message.content

    if type(answer) ~= "string" or answer == "" then
        return false, provider.name .. " returned no message.", response.StatusCode
    end

    answer = stripThinkingTags(answer)

    if answer == "" then
        return false, provider.name .. " returned no message.", response.StatusCode
    end

    return true, answer, response.StatusCode
end

local function isRateLimited(statusCode, message)
    if statusCode == 429 then
        return true
    end

    local lowered = (message or ""):lower()

    return lowered:find("rate limit") ~= nil
        or lowered:find("rate_limit") ~= nil
        or lowered:find("too many requests") ~= nil
end

local function isDailyLimitError(message)
    local lowered = (message or ""):lower()

    return lowered:find("tpd") ~= nil
        or lowered:find("rpd") ~= nil
        or lowered:find("per day") ~= nil
        or lowered:find("daily") ~= nil
end

local function isTokenLimitError(message)
    local lowered = message:lower()

    return lowered:find("token") ~= nil
        or lowered:find("context length") ~= nil
        or lowered:find("context_length") ~= nil
        or lowered:find("too long") ~= nil
        or lowered:find("reduce the length") ~= nil
end

local function isEmptyMessageError(message)
    return message:find("returned no message", 1, true) ~= nil
end

local function attemptModel(provider, apiKey, model, messages)
    local ok, result, statusCode = requestCompletion(provider, apiKey, model, messages)

    if not ok and isEmptyMessageError(result) then
        task.wait(1.2)
        ok, result, statusCode = requestCompletion(provider, apiKey, model, messages)
    end

    return ok, result, statusCode
end

local function buildCandidateModels(provider, preferredModel)
    local list = {preferredModel}

    for _, model in ipairs(provider.models) do
        if model ~= preferredModel then
            table.insert(list, model)
        end
    end

    return list
end

local function tryModels(provider, apiKey, messages, preferredModel)
    local candidates = buildCandidateModels(provider, preferredModel)
    local lastError = "No models available."

    for index, model in ipairs(candidates) do
        local ok, result, statusCode = attemptModel(provider, apiKey, model, messages)

        if ok then
            if index > 1 then
                notify("Rate limited — switched to " .. model, "info")
            end

            return true, result
        end

        lastError = result

        if not isRateLimited(statusCode, result) then
            return false, result
        end
    end

    return false, lastError
end

local function sanitizeInput(text)
    if not text then
        return ""
    end

    text = text:gsub("%s+", " ")
    text = text:match("^%s*(.-)%s*$")

    return text
end

local function describeSpeaker(who)
    if who.DisplayName ~= "" and who.DisplayName ~= who.Name then
        return who.DisplayName .. " (@" .. who.Name .. ")"
    end

    return who.Name
end

local function getGroqApiKeys()
    local keys = {}

    for key in (settings.groqApi or ""):gmatch("[^,]+") do
        local trimmed = key:match("^%s*(.-)%s*$")

        if trimmed ~= "" then
            table.insert(keys, trimmed)
        end
    end

    return keys
end

local groqKeyIndex = 1

local function askAI(userId, userText, speakerPlayer, isRetry)
    if not settings.enabled then
        return false, "AI is disabled."
    end

    local provider = PROVIDERS[settings.provider]
    local model = settings[settings.provider .. "Model"]

    local apiKeys

    if settings.provider == "groq" then
        apiKeys = getGroqApiKeys()
    else
        local singleKey = settings[settings.provider .. "Api"]
        apiKeys = singleKey ~= "" and {singleKey} or {}
    end

    if #apiKeys == 0 then
        return false, "No " .. provider.name .. " API key has been configured."
    end

    if model == "" then
        return false, "No model has been configured."
    end

    if #userText > MAX_USER_MESSAGE_LEN then
        userText = userText:sub(1, MAX_USER_MESSAGE_LEN) .. "..."
    end

    local speakerName = describeSpeaker(speakerPlayer)
    local convo = getConversation(userId)
    local messages = {}

    local combinedSystemPrompt = buildSystemPrompt(speakerPlayer, speakerName)

    if settings.prompt ~= "" then
        combinedSystemPrompt = settings.prompt .. "\n\n" .. combinedSystemPrompt
    end

    table.insert(messages, {
        role = "system",
        content = combinedSystemPrompt
    })

    for _, entry in ipairs(convo) do
        table.insert(messages, {
            role = entry.role,
            content = entry.content
        })
    end

    table.insert(messages, {
        role = "user",
        content = userText
    })

    local startIndex = (groqKeyIndex >= 1 and groqKeyIndex <= #apiKeys) and groqKeyIndex or 1
    local ok, result

    for attempt = 1, #apiKeys do
        local keyIndex = ((startIndex - 1 + attempt - 1) % #apiKeys) + 1

        ok, result = tryModels(provider, apiKeys[keyIndex], messages, model)

        if ok then
            groqKeyIndex = keyIndex
            break
        end

        if settings.provider ~= "groq" or #apiKeys <= 1 or not isDailyLimitError(result) then
            break
        end

        notify("Groq key " .. keyIndex .. " hit its daily limit — switching to the next key.", "info")
    end

    if not ok then
        if not isRetry and isTokenLimitError(result) then
            table.clear(convo)
            notify("Conversation was too long — memory trimmed automatically.", "info")
            return askAI(userId, userText, speakerPlayer, true)
        end

        return false, result
    end

    pushMessage(convo, "user", userText)
    pushMessage(convo, "assistant", result)

    return true, result
end

clearButton.MouseButton1Click:Connect(function()
    table.clear(conversations)
    clearHistory()
    notify("Conversation memory cleared.", "success")
end)

local sending = false

sendButton.MouseButton1Click:Connect(function()
    if sending then
        return
    end

    local text = sanitizeInput(messageBox.Text)

    if text == "" then
        return
    end

    sending = true
    sendButton.Text = "..."
    lastInteractionTime = os.clock()

    messageBox.Text = ""

    addMessage("You", text)

    task.spawn(function()
        local ok, result = askAI(player.UserId, text, player)

        if ok then
            addMessage("AI", processReply(result))
        else
            addMessage("System", result)
            notify(result, "error")
        end

        sending = false
        sendButton.Text = "Send"
    end)
end)

messageBox.FocusLost:Connect(function(enterPressed)
    if enterPressed and not UserInputService.TouchEnabled then
        sendButton:Activate()
    end
end)

local function openAiWindow()
    aiWindow.Visible = true
    aiWindow.BackgroundTransparency = 1

    local scale = Instance.new("UIScale")
    scale.Scale = 0.94
    scale.Parent = aiWindow

    TweenService:Create(aiWindow, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        BackgroundTransparency = 0
    }):Play()

    TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Scale = 1
    }):Play()
end

local MAX_CHAT_LEN = 190
local lastTriggered = {}

local function withinSpeechRange(otherPlayer)
    if settings.range <= 0 then
        return true
    end

    local myChar = player.Character
    local theirChar = otherPlayer.Character

    if not myChar or not theirChar then
        return false
    end

    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    local theirRoot = theirChar:FindFirstChild("HumanoidRootPart")

    if not myRoot or not theirRoot then
        return false
    end

    return (myRoot.Position - theirRoot.Position).Magnitude <= settings.range
end

speakInGameChat = function(text)
    for i = 1, #text, MAX_CHAT_LEN do
        local chunk = text:sub(i, i + MAX_CHAT_LEN - 1)

        pcall(function()
            if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
                local channel = TextChatService.TextChannels
                    and TextChatService.TextChannels:FindFirstChild("RBXGeneral")

                if channel then
                    channel:SendAsync(chunk)
                end
            else
                player:Chat(chunk)
            end
        end)

        task.wait(0.15)
    end
end

local function listCommandsFor(userId)
    local lines = {"!models", "!cmds"}
    local owner = isOwner(userId)
    local entry = getAdminEntry(userId)

    if owner or (entry and entry.canChangeProvider) then
        table.insert(lines, "!provider")
    end

    if owner or (entry and entry.canChangeModel) then
        table.insert(lines, "!model")
    end

    if owner or entry then
        table.insert(lines, "!blacklist")
        table.insert(lines, "!unblacklist")
    end

    if owner then
        table.insert(lines, "!admin")
        table.insert(lines, "!unadmin")
        table.insert(lines, "!limit")
    end

    return table.concat(lines, " ")
end

local function handleChatCommand(fromPlayer, message)
    if isBlacklisted(fromPlayer.UserId) then
        return
    end

    local rest = message:sub(2)
    local commandWord, argString = rest:match("^(%S*)%s*(.*)$")
    commandWord = (commandWord or ""):lower()
    argString = argString or ""

    if commandWord == "" then
        return
    end

    if commandWord == "cmds" then
        speakInGameChat(fromPlayer.Name .. ", commands: " .. listCommandsFor(fromPlayer.UserId))
        return
    end

    if commandWord == "models" then
        local providerModels = PROVIDERS[settings.provider].models
        local aliasList = {}

        for _, modelName in ipairs(providerModels) do
            table.insert(aliasList, aliasForModel(settings.provider, modelName))
        end

        speakInGameChat("Models (" .. PROVIDERS[settings.provider].name .. "): " .. table.concat(aliasList, ", "))
        return
    end

    if not isAdmin(fromPlayer.UserId) then
        return
    end

    local adminEntry = getAdminEntry(fromPlayer.UserId)
    local owner = isOwner(fromPlayer.UserId)

    if commandWord == "provider" then
        if not (owner or (adminEntry and adminEntry.canChangeProvider)) then
            speakInGameChat(fromPlayer.Name .. ", you don't have permission to change the provider.")
            return
        end

        local target = argString:lower()
        local matched = nil

        for _, key in ipairs(PROVIDER_ORDER) do
            if key == target or PROVIDERS[key].name:lower() == target then
                matched = key
                break
            end
        end

        if not matched then
            speakInGameChat("Unknown provider. Try: " .. table.concat(PROVIDER_ORDER, ", "))
            return
        end

        settings.provider = matched
        saveSettings()
        refreshProviderFields()
        speakInGameChat("Provider switched to " .. PROVIDERS[matched].name .. ".")
        return
    end

    if commandWord == "model" then
        if not (owner or (adminEntry and adminEntry.canChangeModel)) then
            speakInGameChat(fromPlayer.Name .. ", you don't have permission to change the model.")
            return
        end

        if argString == "" then
            speakInGameChat("Usage: !model <alias>")
            return
        end

        if adminEntry and not owner and type(adminEntry.allowedModels) == "table" and next(adminEntry.allowedModels) then
            if not adminEntry.allowedModels[argString:lower()] then
                local allowedList = {}

                for allowedAlias in pairs(adminEntry.allowedModels) do
                    table.insert(allowedList, allowedAlias)
                end

                speakInGameChat(fromPlayer.Name .. ", you're limited to: " .. table.concat(allowedList, ", "))
                return
            end
        end

        local modelName = modelForAlias(settings.provider, argString)

        if not modelName then
            speakInGameChat("Unknown model alias. Try !models to see the list.")
            return
        end

        settings[settings.provider .. "Model"] = modelName
        saveSettings()
        refreshProviderFields()
        speakInGameChat("Model switched to " .. argString .. ".")
        return
    end

    if commandWord == "blacklist" then
        local targetPlayer = findPlayerByName(argString)

        if not targetPlayer then
            speakInGameChat("Player not found.")
            return
        end

        if isOwner(targetPlayer.UserId) then
            return
        end

        for i, entry in ipairs(settings.admins) do
            if entry.userId == targetPlayer.UserId then
                table.remove(settings.admins, i)
                break
            end
        end

        for _, entry in ipairs(settings.blacklist) do
            if entry.userId == targetPlayer.UserId then
                speakInGameChat(targetPlayer.Name .. " is already blacklisted.")
                return
            end
        end

        table.insert(settings.blacklist, {userId = targetPlayer.UserId, name = targetPlayer.Name})
        saveSettings()
        refreshAdminRows()
        refreshBlacklistRows()
        speakInGameChat(targetPlayer.Name .. " has been blacklisted.")
        return
    end

    if commandWord == "unblacklist" then
        local removed = false

        for i, entry in ipairs(settings.blacklist) do
            if entry.name:lower() == argString:lower() then
                table.remove(settings.blacklist, i)
                removed = true
                break
            end
        end

        if removed then
            saveSettings()
            refreshBlacklistRows()
            speakInGameChat(argString .. " removed from blacklist.")
        else
            speakInGameChat(argString .. " was not blacklisted.")
        end

        return
    end

    if not owner then
        return
    end

    if commandWord == "admin" then
        local targetPlayer = findPlayerByName(argString)

        if not targetPlayer then
            speakInGameChat("Player not found.")
            return
        end

        if isOwner(targetPlayer.UserId) then
            return
        end

        if getAdminEntry(targetPlayer.UserId) then
            speakInGameChat(targetPlayer.Name .. " is already an admin.")
            return
        end

        table.insert(settings.admins, {
            userId = targetPlayer.UserId,
            name = targetPlayer.Name,
            canChangeProvider = true,
            canChangeModel = true,
            allowedModels = {}
        })

        saveSettings()
        refreshAdminRows()
        speakInGameChat(targetPlayer.Name .. " is now admin!")
        return
    end

    if commandWord == "unadmin" then
        local targetPlayer = findPlayerByName(argString)
        local targetName = targetPlayer and targetPlayer.Name or argString
        local targetUserId = targetPlayer and targetPlayer.UserId
        local removed = false

        for i, entry in ipairs(settings.admins) do
            if (targetUserId and entry.userId == targetUserId) or entry.name:lower() == argString:lower() then
                table.remove(settings.admins, i)
                removed = true
                break
            end
        end

        if removed then
            saveSettings()
            refreshAdminRows()
            speakInGameChat(targetName .. " is no longer admin.")
        else
            speakInGameChat(targetName .. " was not an admin.")
        end

        return
    end

    if commandWord == "limit" then
        local targetName, aliasListStr = argString:match("^(%S+)%s+(.+)$")

        if not targetName then
            speakInGameChat("Usage: !limit <user> <alias1,alias2,...|all>")
            return
        end

        local targetPlayer = findPlayerByName(targetName)
        local entry = targetPlayer and getAdminEntry(targetPlayer.UserId)

        if not entry then
            speakInGameChat(targetName .. " is not an admin.")
            return
        end

        if aliasListStr:lower() == "all" then
            entry.allowedModels = {}
            saveSettings()
            speakInGameChat(entry.name .. " is no longer limited to specific models.")
            return
        end

        local allowed = {}

        for aliasPart in aliasListStr:gmatch("[^,]+") do
            local trimmedAlias = aliasPart:match("^%s*(.-)%s*$"):lower()

            if trimmedAlias ~= "" then
                allowed[trimmedAlias] = true
            end
        end

        entry.allowedModels = allowed
        saveSettings()
        speakInGameChat(entry.name .. " limited to: " .. aliasListStr)
        return
    end
end

local function handleIncomingChat(fromPlayer, message)
    if not settings.enabled then
        return
    end

    if isBlacklisted(fromPlayer.UserId) then
        return
    end

    message = sanitizeInput(message)

    if message == "" then
        return
    end

    if not withinSpeechRange(fromPlayer) then
        return
    end

    local now = os.clock()
    local last = lastTriggered[fromPlayer.UserId]

    if last and (now - last) < settings.cooldown then
        return
    end

    lastTriggered[fromPlayer.UserId] = now
    lastInteractionTime = now

    addMessage(fromPlayer.Name, message)

    task.spawn(function()
        local ok, result = askAI(fromPlayer.UserId, message, fromPlayer)

        if ok then
            local cleaned = processReply(result)
            addMessage("AI", cleaned)
            speakInGameChat(cleaned)
        else
            addMessage("System", result)
            notify(result, "error")
        end
    end)
end

local function hookPlayer(otherPlayer)
    otherPlayer.Chatted:Connect(function(message)
        if message:sub(1, 1) == "!" then
            handleChatCommand(otherPlayer, message)
            return
        end

        if otherPlayer == player then
            return
        end

        handleIncomingChat(otherPlayer, message)
    end)

    if otherPlayer == player then
        return
    end

    otherPlayer.AncestryChanged:Connect(function(_, parent)
        if not parent then
            conversations[otherPlayer.UserId] = nil
            lastTriggered[otherPlayer.UserId] = nil
            hitCounts[otherPlayer.UserId] = nil
        end
    end)
end

for _, existingPlayer in ipairs(Players:GetPlayers()) do
    hookPlayer(existingPlayer)
end

Players.PlayerAdded:Connect(hookPlayer)

local IDLE_GESTURES = {"wave", "lookaround", "tapfoot", "shrug", "nod"}

task.spawn(function()
    while true do
        task.wait(15)

        if settings.idleGestures and settings.enabled and (os.clock() - lastInteractionTime) > 90 then
            local character = player.Character

            if character and character:FindFirstChildOfClass("Humanoid") then
                local gestureName = IDLE_GESTURES[math.random(1, #IDLE_GESTURES)]

                if ACTIONS[gestureName] and not settings.disabledActions[gestureName] then
                    enqueueActions({{name = gestureName, param = nil}}, false)
                end
            end

            lastInteractionTime = os.clock()
        end
    end
end)

updateEnabled()
showPage("chat")
openAiWindow()
notify("AI companion initialized.", "success")
addMessage(
    "System",
    "AI Chatbot initialized. Configure your provider in Settings."
)
