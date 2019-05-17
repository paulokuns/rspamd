--[[[
-- @module lua_maps_expressions
-- This module contains routines to combine maps, selectors and expressions
-- in a generic framework
@example
whitelist_ip_from = {
  rules {
    ip {
      selector = "ip";
      map = "/path/to/whitelist_ip.map";
    }
    from {
      selector = "from(smtp)";
      map = "/path/to/whitelist_from.map";
    }
  }
  expression = "ip & from";
}
--]]

--[[
Copyright (c) 2019, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

local lua_selectors = require "lua_selectors"
local lua_maps = require "lua_maps"
local rspamd_expression = require "rspamd_expression"
local rspamd_logger = require "rspamd_logger"
local fun = require "fun"

local exports = {}

local function process_func(elt, task)
  local matched = {}
  local function process_atom(atom)
    local rule = elt.rules[atom]
    local res = 0

    local function match_rule(val)
      local map_match = rule.map:get_key(val)
      if map_match then
        res = 1.0
        matched[rule.name] = {
          matched = val,
          value = map_match
        }
      end
    end

    local values = rule.selector(task)

    if values then
      if type(values) == 'table' then
        for _,val in ipairs(values) do
          if res == 0 then
            match_rule(val)
          end
        end
      else
        match_rule(values)
      end
    end

    return res
  end

  local res = elt.expr:process(process_atom)

  if res then
    return res,matched
  end

  return nil
end

local function create(cfg, obj, module_name)
  if not module_name then module_name = 'lua_maps_expressions' end

  if not obj or not obj.rules or not obj.expression then
    rspamd_logger.errx(cfg, 'cannot add maps combination for module %s: required elements are missing',
        module_name)
    return nil
  end

  local ret = {
    process = process_func,
    rules = {},
    module_name = module_name
  }

  for name,rule in pairs(obj.rules) do
    local sel = lua_selectors.parse_selector(cfg, rule.selector)

    if not sel then
      rspamd_logger.errx(cfg, 'cannot add selector for element %s in module %s',
          name, module_name)
    end

    local map = lua_maps.map_add_from_ucl(rule.map, rule.type or 'set',
        obj.description or module_name)
    if not map then
      rspamd_logger.errx(cfg, 'cannot add map for element %s in module %s',
          name, module_name)
    end

    if sel and map then
      ret.rules[name] = {
        selector = sel,
        map = map,
      }
    else
      return nil
    end
  end

  -- Now process and parse expression
  local function parse_atom(str)
    local atom = table.concat(fun.totable(fun.take_while(function(c)
      if string.find(', \t()><+!|&\n', c) then
        return false
      end
      return true
    end, fun.iter(str))), '')

    if ret.rules[atom] then
      return atom
    end

    rspamd_logger.errx(cfg, 'use of undefined element "%s" when parsing maps expression for %s',
        atom, module_name)

    return nil
  end
  local expr = rspamd_expression.create(obj.expression, parse_atom, rspamd_config:get_mempool())

  if not expr then
    rspamd_logger.errx(cfg, 'cannot add map expression for module %s',
        module_name)
    return nil
  end

  ret.expr = expr

  return ret
end

exports.create = create

return exports