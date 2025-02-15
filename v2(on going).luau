-- Much cleaner simpler faster than my first try (the one on roblox dev forum)
-- Pack function is currently 100x faster than v1, now I need to add the value
-- types serializer functions, the Unpack function, and at the very end of development
-- some compression algorithm made from scratch + Deflate compression as an optional when packing

-- Get from raw API dump from: https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/refs/heads/roblox/API-Dump.json
local API = game:GetService("HttpService"):JSONDecode(require(script.API))

-- Initialize tables for caching class-related data
local classes = {}
local classesData = {}
local classesIDMap = {}
local classesPropertyMap = {}
local classesPropertyNames = {}
local classesPropertyTypes = {}
local classesCreatable = {}

do
	-- Function to cache class properties and map them to property IDs
	-- It saves property names, types, and IDs for later serialization
	local function CacheClassProperty(prop: {}, propID: number, properties: {}, propertyNames: {}, propertyTypes: {})
		if prop.MemberType ~= "Property" then return propID end

		local propName = prop.Name
		propID += 1

		properties[propName] = propID
		propertyNames[propID] = propName

		-- Save the value type of the property (Category, Name)
		propertyTypes[propID] = {prop.ValueType.Category, prop.ValueType.Name}

		return propID
	end

	-- Function to cache data related to a class, including its properties
	-- Loops through class members and stores their relevant data
	local function CacheClass(class: {}, classID: number)
		local propID = 0
		local properties = classesPropertyMap[classID] or {}
		local propertyNames = classesPropertyNames[classID] or {}
		local propertyTypes = classesPropertyTypes[classID] or {}

		-- Loop through each property in the class and cache relevant data
		for i, prop in class.Members do
			local tags = prop.Tags
			if tags and table.find(tags, "ReadOnly") then continue end

			-- Skip properties that can't be written to
			if prop.Security.Write ~= "None" then continue end

			-- Cache the property data
			propID = CacheClassProperty(prop, propID, properties, propertyNames, propertyTypes)
		end

		-- Save the cached properties to their respective tables
		classesPropertyMap[classID] = properties
		classesPropertyNames[classID] = propertyNames
		classesPropertyTypes[classID] = propertyTypes
	end

	-- Cache all classes data from the API dump
	for classID, class in API.Classes do
		local tags = class.Tags
		if not tags or not table.find(tags, "NotCreatable") then
			classesCreatable[classID] = true
		end

		local className = class.Name

		-- Store basic class data (name, ID, etc.)
		classes[className] = classID
		classesData[classID] = class
		classesIDMap[classID] = className

		-- Cache class properties
		CacheClass(class, classID)
	end

	-- Loop through each class and its superclass to ensure all relevant data is cached
	-- This handles the case where classes inherit from other classes
	local rootSuperclass = "<<<ROOT>>>"
	for classID, class in API.Classes do
		repeat
			local superclass = class.Superclass
			if superclass == rootSuperclass then break end

			-- Get the data of the superclass and cache it
			class = classesData[classes[superclass]]
			CacheClass(class, classID)
		until false
	end
end

-- Cache default values for each creatable class
-- This uses Instance.new to create an object and grab its default property values
local classesDefaultValues = {}
for classID, _ in classesCreatable do
	local class = classesData[classID]
	local className = class.Name

	-- Attempt to create a new instance of the class
	local ok, obj = pcall(Instance.new, className)
	if not ok then
		classesCreatable[classID] = false
		continue
	end

	-- Cache the default values of the object's properties
	local defaultValues = {}
	for propID, propName in classesPropertyNames[classID] do
		defaultValues[propID] = obj[propName]
	end

	classesDefaultValues[classID] = defaultValues

	-- Destroy the object used to get default values
	obj:Destroy()
end

local separator = ";"

-- Function to serialize an instance into a string format
-- It records the class ID, properties, and their values (only those that differ from default)
local function GetSerializedInstance(obj: Instance, env: {Instance})
	local className = obj.ClassName
	local classID = classes[className]

	-- Init instance serialized data with its class ID
	local data = `{string.pack("I2", classID)}{separator}`

	-- Get only the properties different from their default values
	local defaultProperties = classesDefaultValues[classID]
	local totalProperties = 0
	local propertyData = ""
	for propID, propName in classesPropertyNames[classID] do
		local newValue = obj[propName]
		if typeof(newValue) == "Instance" then
			-- Convert any Instance type property to its reference in the environment
			newValue = env[newValue]

			if not newValue then continue end
		elseif defaultProperties[propID] == newValue then continue end

		-- If the property has a new value, add it to the serialized data
		totalProperties += 1
		propertyData ..= `{string.char(propID)}{obj[propName]}{separator}`
	end

	-- Append total property count and data
	data ..= `{string.char(totalProperties)}{separator}`
	data ..= propertyData

	return data
end

-- Function to recursively serialize a model and all of its children
local function PackSerializedModel(obj: Instance, env: {Instance})
	local data = GetSerializedInstance(obj, env)

	-- Append serialized data of all children of the object
	local children = obj:GetChildren()
	data ..= `{string.pack("I2", #children)}{separator}`

	for i, child in children do
		data ..= PackSerializedModel(child, env)
	end

	return data
end

local ObjPacker = {}

-- Public function to initiate the packing of an object and its descendants
function ObjPacker.Pack(obj: Instance)
	local env = {}

	-- Map each descendant to its reference in the environment
	for i, v in obj:GetDescendants() do
		env[v] = i
	end

	-- Start the serialization process
	return PackSerializedModel(obj, env)
end

-- Example usage: Serialize the Baseplate from the workspace
local model = ObjPacker.Pack(workspace.Baseplate)
print(model)
