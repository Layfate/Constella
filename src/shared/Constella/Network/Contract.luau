--!strict
--!nolint UnreachableCode
--[=[
	Constella.Network.Contract

	A contract describes one namespace's endpoints in a module that both the
	server and the client require: each endpoint's name, its argument
	Schema, and (for the type checker) its argument and result types.
	`Server:EventOf(contract.X)` and `Client:EventOf(contract.X)` then give
	typed endpoints, so the handler, the call and the declaration can't
	drift apart.

	```lua
	-- ReplicatedStorage.Shared.ShopContract
	local Constella = require(ReplicatedStorage.Packages.Constella)
	local Contract, Check = Constella.Network.Contract, Constella.Network.Check

	return Contract.define({
		Namespace = "Shop",
		-- client -> server, answered by the server: (itemId) -> (result, balance)
		Purchase = Contract.fn({ Check.string(20) }) :: Constella.ContractFunction<(string), (string, number)>,
		-- server -> client only (no Schema)
		CoinsChanged = Contract.event() :: Constella.ContractEvent<(number)>,
	})
	```

	The types are `Constella.ContractEvent<T...>` and
	`Constella.ContractFunction<A..., R...>` (exported types are only
	reachable through a module bound directly to `require`).

	What goes where
	- The contract is shared code: clients can read it, including its
	  Schemas. Schemas check the SHAPE of a request, which is no secret.
	  Anything that depends on server-only knowledge (ownership, prices,
	  cooldowns) belongs in the server's Authorize hook or handler, never in
	  a contract.
	- Rate limits, payload limits, Authorize and Unreliable stay in the
	  server's config (`server:EventOf(contract.X, config)`).

	At runtime a contract endpoint is the same endpoint `Server:Event` /
	`Server:Function` creates, behind the same five gates; the types are
	the only difference.

	Luau can't check that a Schema matches the declared types:
	`Contract.fn({ Check.number() }) :: Constella.ContractFunction<(string), ()>`
	type-checks. Keep each cast next to its Schema.
]=]

--- An event endpoint carrying the arguments `T...` (in both directions).
--- Without a Schema it only goes from server to client.
export type Event<T...> = {
	Kind: "Event",
	Name: string,
	Namespace: string,
	Schema: { Validator }?,
	--- Never set at runtime: carries the argument types for the type checker.
	--- (Declared as required: Luau infers `T...` through a required field,
	--- but not through an optional one.)
	_types: (T...) -> (),
}

--- A function endpoint: the client sends `A...`, the server answers `R...`.
export type Function<A..., R...> = {
	Kind: "Function",
	Name: string,
	Namespace: string,
	Schema: { Validator },
	--- Never set at runtime: carries the argument and result types for the
	--- type checker (required for the same reason as in Event).
	_types: (A...) -> R...,
}

local PREFIX = "[Constella.Network] "
local NAME_PATTERN = "^[%w_]+$"

-- Every endpoint this module created, so a hand-made table can't pass as
-- one. Weak keys: an unused contract can still be collected.
local endpoints: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function isName(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 50 and string.match(value, NAME_PATTERN) ~= nil
end

-- A frozen copy, so changing the caller's array later can't change what
-- the server validates.
local function copySchema(schema: any, what: string, level: number): { Validator }
	if type(schema) ~= "table" then
		error(PREFIX .. ("%s Schema must be an array of validators"):format(what), level)
	end
	local count = 0
	for _ in schema do
		count += 1
	end
	if count ~= #schema then
		error(PREFIX .. ("%s Schema must be an array of validators"):format(what), level)
	end
	for _, validator in schema do
		if type(validator) ~= "function" then
			error(PREFIX .. ("%s Schema must be an array of validators"):format(what), level)
		end
	end
	return table.freeze(table.clone(schema))
end

local Contract = {}

--- An event endpoint. Pass a Schema to accept client fires; without one the
--- event only goes from server to client. Cast the result to
--- `Constella.ContractEvent<(...)>` to declare its argument types.
function Contract.event(schema: { Validator }?): Event<...any>
	local endpoint = {
		Kind = "Event",
		Schema = if schema ~= nil then copySchema(schema, "Event", 3) else nil,
	}
	endpoints[endpoint] = true
	return (endpoint :: any) :: Event<...any>
end

--- A function endpoint. A Schema is required (use {} for no arguments).
--- Cast the result to `Constella.ContractFunction<(args), (results)>`.
function Contract.fn(schema: { Validator }): Function<...any, ...any>
	if schema == nil then
		error(PREFIX .. "Contract.fn needs a Schema (use {} for no arguments)", 2)
	end
	local endpoint = { Kind = "Function", Schema = copySchema(schema, "Function", 3) }
	endpoints[endpoint] = true
	return (endpoint :: any) :: Function<...any, ...any>
end

--- Names the endpoints after their keys, checks them and freezes the
--- contract. `Namespace` is required; every other key must be an endpoint
--- from `Contract.event` or `Contract.fn`, used in this contract only.
function Contract.define<T>(contract: T): T
	if type(contract) ~= "table" then
		error(PREFIX .. "Contract.define expects a table", 2)
	end
	local namespace = (contract :: any).Namespace
	if not isName(namespace) then
		error(
			PREFIX
				.. ("Contract Namespace must be 1-50 letters, digits or underscores, got %s"):format(
					tostring(namespace)
				),
			2
		)
	end
	for name, endpoint in contract :: any do
		if name == "Namespace" then
			continue
		end
		if not isName(name) then
			error(
				PREFIX .. ("Endpoint name must be 1-50 letters, digits or underscores, got %s"):format(tostring(name)),
				2
			)
		end
		if not endpoints[endpoint] then
			error(PREFIX .. ("'%s' must be made with Contract.event or Contract.fn"):format(name), 2)
		end
		if endpoint.Name ~= nil then
			error(
				PREFIX .. ("'%s' is already '%s' in contract '%s'"):format(name, endpoint.Name, endpoint.Namespace),
				2
			)
		end
	end
	for name, endpoint in contract :: any do
		if name ~= "Namespace" then
			endpoint.Name = name
			endpoint.Namespace = namespace
			table.freeze(endpoint)
		end
	end
	if not table.isfrozen(contract :: any) then
		table.freeze(contract :: any)
	end
	return contract
end

--- True if `value` is an endpoint of a defined contract, optionally of
--- the given kind ("Event" or "Function").
function Contract.is(value: any, kind: ("Event" | "Function")?): boolean
	return endpoints[value] == true and value.Name ~= nil and (kind == nil or value.Kind == kind)
end

do
	return table.freeze(Contract)
end

-- Type-only import: these lines come after the module has returned, so they
-- never run and Contract doesn't load Check. (Type aliases are visible in
-- the whole file, so the types above can use Validator.)
local Check = require(script.Parent.Check)
type Validator = Check.Validator
