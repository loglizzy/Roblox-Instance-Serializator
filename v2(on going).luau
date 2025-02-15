-- Much cleaner simpler faster than the my first try(the one on roblox dev forum)
-- Pack function is currently 100x faster than v1, now i need to add the value
-- types serializer functions, the Unpack function, and at the very end of development
-- some compression algorithm made from scratch + Deflate compression as an optional when packing

-- Get from raw API dump from: https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/refs/heads/roblox/API-Dump.json
local API = game:GetService("HttpService"):JSONDecode(require(script.API))

-- Caching classes data
local classes = {}
local classesData = {}
local classesIDMap = {}
local classesPropertyMap = {}
local classesPropertyNames = {}
local classesPropertyTypes = {}
local classesCreatable = {}
do
	local function CacheClassProperty(prop: {}, propID: number, properties: {}, propertyNames: {}, propertyTypes: {})
		if prop.MemberType ~= "Property" then return propID end

		local propName = prop.Name

		propID += 1

		properties[propName] = propID
		propertyNames[propID] = propName

		propertyTypes[propID] = {prop.ValueType.Category, prop.ValueType.Name}

		return propID
	end

	local function CacheClass(class: {}, classID: number)
		local propID = 0
		local properties = classesPropertyMap[classID] or {}
		local propertyNames = classesPropertyNames[classID] or {}
		local propertyTypes = classesPropertyTypes[classID] or {}
		for i, prop in class.Members do
			local tags = prop.Tags
			if tags and table.find(tags, "ReadOnly") then continue end

			if prop.Security.Write ~= "None" then continue end

			propID = CacheClassProperty(prop, propID, properties, propertyNames, propertyTypes)
		end

		classesPropertyMap[classID] = properties
		classesPropertyNames[classID] = propertyNames
		classesPropertyTypes[classID] = propertyTypes
	end

	for classID, class in API.Classes do
		local tags = class.Tags
		if not tags or not table.find(tags, "NotCreatable") then
			classesCreatable[classID] = true
		end

		local className = class.Name

		classes[className] = classID
		classesData[classID] = class
		classesIDMap[classID] = className

		-- Cache class properties
		CacheClass(class, classID)
	end

	local rootSuperclass = "<<<ROOT>>>"
	for classID, class in API.Classes do
		repeat
			local superclass = class.Superclass
			if superclass == rootSuperclass then break end

			class = classesData[classes[superclass]]

			CacheClass(class, classID)
		until false
	end
end

local classesDefaultValues = {}
for classID, _ in classesCreatable do
	local class = classesData[classID]
	local className = class.Name

	local ok, obj = pcall(Instance.new, className)
	if not ok then
		classesCreatable[classID] = false
		continue
	end

	-- Cache class default values
	local defaultValues = {}
	for propID, propName in classesPropertyNames[classID] do
		defaultValues[propID] = obj[propName]
	end

	classesDefaultValues[classID] = defaultValues

	-- Destroy object used to get default values
	obj:Destroy()
end

local separator = ";"
local function GetSerializedInstance(obj: Instance, env: {Instance})
	local className = obj.ClassName
	local classID = classes[className]

	-- Init instance serialized data with it's class ID
	local data = `{string.pack("I2", classID)}{separator}`

	-- Get only the properties different from their default values
	local defaultProperties = classesDefaultValues[classID]
	local totalProperties = 0
	local propertyData = ""
	for propID, propName in classesPropertyNames[classID] do
		local newValue = obj[propName]
		if typeof(newValue) == "Instance" then
			newValue = env[newValue]

			if not newValue then continue end
		elseif defaultProperties[propID] == newValue then continue end

		totalProperties += 1
		propertyData ..= `{string.char(propID)}{obj[propName]}{separator}`
	end

	-- Append total property values
	data ..= `{string.char(totalProperties)}{separator}`

	-- Append property values data"
	data ..= propertyData

	return data
end

local function PackSerializedModel(obj: Instance, env: {Instance})	
	local data = GetSerializedInstance(obj, env)

	-- append children serialized data
	local children = obj:GetChildren()
	data ..= `{string.pack("I2", #children)}{separator}`

	for i, child in children do
		data ..= PackSerializedModel(child, env)
	end

	return data
end

local ObjPacker = {}
function ObjPacker.Pack(obj: Instance)
	local env = {}
	for i, v in obj:GetDescendants() do
		env[v] = i
	end

	return PackSerializedModel(obj, env)
end

local model = ObjPacker.Pack(workspace.Baseplate)
print(model)
