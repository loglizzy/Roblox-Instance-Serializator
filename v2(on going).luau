-- Much cleaner simpler faster than my first try (the one on roblox dev forum)
-- Pack function is like 3000x faster than the one used in v1, now I need to add the value
-- types serializer functions, the Unpack function, and at the very end of development
-- some compression algorithm made from scratch + Deflate compression as an optional when packing

-- Tests:
-- Big City map with 9015 parts was serialized in 1.2405s(thing i know would be great for perfomance:
-- every map/model will always have a lot of identical Instances with a few different properties so it would
-- be super great for perfomance and output size if i add 1 header of 2 bytes to each Instance serial data saying
-- an index for an Instance in the model has at least 1 identical property to it)

-- Get from raw API dump from: https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/refs/heads/roblox/API-Dump.json
local API = game:GetService("HttpService"):JSONDecode(require(script.API))

-- Initialize tables for caching class-related data
local classes = {}
local classesData = {}
local classesIDMap = {}
local classesPropertyMap = {}
local classesPropertyNames = {}
local classesCreatable = {}
local propertiesSerializer = {}

local formatI8 = "I8"
local formatSignedI8 = "i8"
local formatI4 = "I4"
local formatSignedI4 = "i4"
local formatI2 = "I2"
local formatSignedFloat = "f"
local formatSignedDouble = "d"
local formatColor = "I1I1I1"
local formatCFrame = "fffffff" -- using double instead of float would be more precise but it's also 2x bigger
local formatVector3 = "ddd"
local formatNumberRange = "ff"
local formatUDim = "fi4"
local formatUDim2 = "fi4fi4"
local formatPhysicalProperties = "HHHHH"
local valueSeparator = ","
local serializers = {
	CFrame = function(x: CFrame)
		local x, y, z, rX, rY, rZ, rW = x:GetComponents()
		return PackString(formatCFrame, x, y, z, rX, rY, rZ, rW)
	end,
	Vector3 = function(x: Vector3)
		return PackString(formatVector3, x.X, x.Y, x.Z)
	end,
	Color3 = function(x: Color3)
		return PackString(formatColor, x.R, x.G, x.B)
	end,
	BrickColor = function(x: BrickColor)
		return
	end,
	Enum = function(x: EnumItem)
		return PackString(formatI2, x.Value)
	end,
	NumberRange = function(x: NumberRange)
		return PackString(formatNumberRange, x.Min, x.Max)
	end,
	UDim = function(x: UDim)
		return PackString(formatUDim, x.Scale, x.Offset)
	end,
	UDim2 = function(x: UDim2)
		local X, Y = x.X, x.Y
		return PackString(formatUDim2, X.Scale, X.Offset, Y.Scale, Y.Offset)
	end,
	PhysicalProperties = function(x: PhysicalProperties)
		return PackString(formatPhysicalProperties, x.Density, x.Elasticity, x.ElasticityWeight, x.Friction, x.FrictionWeight)
	end,
	Content = function(x: Content)
		return
	end,
	ContentId = function(x: string)
		return PackString(formatI8, tonumber(x:sub(14, #x)))
	end,
	int = function(x: number)
		return PackString(formatSignedI4, x)
	end,
	int64 = function(x: number)
		return PackString(formatSignedI8, x)
	end,
	float = function(x: number)
		return PackString(formatSignedFloat, x)
	end,
	double = function(x: number)
		return PackString(formatSignedDouble, x)
	end,
	bool = function(x: boolean)
		return if x then "Y" else ""
	end,
	string = function(x: string)
		return x
	end,
}

serializers.Size = serializers.Vector3

do
	-- Function to cache class properties and map them to property IDs
	-- It saves property names, types, and IDs for later serialization
	local function CacheClassProperty(prop: {}, propID: number, properties: {}, propertyNames: {}, propertyTypes: {})
		if prop.MemberType ~= "Property" then return propID end

		local propName = prop.Name
		propID += 1

		properties[propName] = propID
		propertyNames[propID] = propName

		if not propertiesSerializer[propName] then
			local serializerFn = serializers[propName]
			if not serializerFn then
				local valueType = prop.ValueType
				serializerFn = serializers[valueType.Category]
					or serializers[valueType.Name]
			end

			propertiesSerializer[propName] = serializerFn
		end

		return propID
	end

	-- Function to cache data related to a class, including its properties
	-- Loops through class members and stores their relevant data
	local function CacheClass(class: {}, classID: number)
		local propID = 0
		local properties = classesPropertyMap[classID] or {}
		local propertyNames = classesPropertyNames[classID] or {}

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

-- Function to serialize an instance into a string format
-- It records the class ID, properties, and their values (only those that differ from default)
local propertySeparator = ";"
local function GetSerializedInstance(obj: Instance, env: {Instance})
	local className = obj.ClassName
	local classID = classes[className]

	-- Init instance serialized data with its class ID
	local data = `{PackString(formatI2, classID)}{propertySeparator}`

	-- Get only the properties different from their default values
	local defaultProperties = classesDefaultValues[classID]
	if not defaultProperties then return "" end
	
	local totalProperties = 0
	local propertyData = ""
	for propID, propName in classesPropertyNames[classID] do
		local newValue = obj[propName]
		if typeof(newValue) == "Instance" then
			-- Convert any Instance type property to its reference in the environment
			newValue = env[newValue]

			if not newValue then continue end
		elseif defaultProperties[propID] == newValue then continue end
		
		local valueSerializerFn = propertiesSerializer[propName]
		
		local serializedValue = obj[propName]
		if valueSerializerFn then
			serializedValue = valueSerializerFn(obj[propName])
		end
		
		if serializedValue == nil then continue end

		-- If the property has a new value, add it to the serialized data
		totalProperties += 1
		propertyData ..= `{CharString(propID)}{serializedValue}{propertySeparator}`
	end

	-- Append total property count and data
	data ..= `{CharString(totalProperties)}{propertySeparator}`
	data ..= propertyData

	return data
end

-- Function to recursively serialize a model and all of its children
local function PackSerializedModel(obj: Instance, env: {Instance})
	local data = GetSerializedInstance(obj, env)

	-- Append serialized data of all children of the object
	local children = obj:GetChildren()
	data ..= `{PackString(formatI2, #children)}{propertySeparator}`

	for i, child in children do
		data ..= PackSerializedModel(child, env)
	end

	return data
end

-- Holds string.pack in an global variable for faster access
-- PackString(...) requires 1 less interpreter instruction than string.pack(...)
PackString = string.pack

-- Same for other frequent functions
CharString = string.char

local ObjPacker = {}

-- Public function to initiate the packing of an object and its descendants
local tobase64 = require(script.Encode).tobase93
local Deflate = require(script.Compression).Deflate
local Compress, Decompress = Deflate.Compress, Deflate.Decompress
function ObjPacker.Pack(obj: Instance, compressionLevel: number?)
	local env = {}

	-- Map each descendant to its reference in the environment
	for i, v in obj:GetDescendants() do
		env[v] = i
	end

	-- Start the serialization process
	local model = PackSerializedModel(obj, env)
	
	-- Compressing model text with Deflate
	model = Compress(model, {
		-- Using compression level 1 as defaul
		-- Compression levels overviewÇ:
		-- Level|Compression percentage|Time efficiency
		-- 0	 -0.01%					-0.001
		-- 1	 74.29%					0.926 (optimal for time)
		-- 2	 75.56%					0.884
		-- 3	 76.36%					0.750
		-- 4	 78.17%					0.571
		-- 5	 79.16%					0.434 (good balanced option)
		-- 6	 79.62%					0.290 (good balanced option)
		-- 7	 79.71%					0.247
		-- 8	 79.74%					0.208
		-- 9	 79.74%					0.216 (best for size efficiency)

		level = compressionLevel or 1
	})
	
	return model
end

-- Example usage: Serialize the Baseplate from the workspace
task.wait(2)

local start = os.clock()
local model = ObjPacker.Pack(workspace["BigCity Folder"])
local took = os.clock() - start
print(model)
print(took)
print(#model.." bytes")
print(math.round(#model/1024).." kb")
