--[[
Copyright (c) 2019, Vsevolod Stakhov <vsevolod@highsecure.ru>
Copyright (c) 2019, Carsten Rosenberg <c.rosenberg@heinlein-support.de>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]] --

local rspamd_logger = require "rspamd_logger"
local lua_util = require "lua_util"
local fun = require "fun"
local lua_scanners = require("lua_scanners").filter('scanner')
local common = require "lua_scanners/common"
local redis_params

local N = "external_services"

if confighelp then
  rspamd_config:add_example(nil, 'external_services',
    "Check messages using external services (e.g. OEM AS engines, DCC, Pyzor etc)",
    [[
external_services {
  # multiple scanners could be checked, for each we create a configuration block with an arbitrary name

  oletools {
    # If set force this action if any virus is found (default unset: no action is forced)
    # action = "reject";
    # If set, then rejection message is set to this value (mention single quotes)
    # If `max_size` is set, messages > n bytes in size are not scanned
    # max_size = 20000000;
    # log_clean = true;
    # servers = "127.0.0.1:10050";
    # cache_expire = 86400;
    # scan_mime_parts = true;
    # extended = false;
    # if `patterns` is specified virus name will be matched against provided regexes and the related
    # symbol will be yielded if a match is found. If no match is found, default symbol is yielded.
    patterns {
      # symbol_name = "pattern";
      JUST_EICAR = "^Eicar-Test-Signature$";
    }
    # mime-part regex matching in content-type or filename
    mime_parts_filter_regex {
      #GEN1 = "application\/octet-stream";
      DOC2 = "application\/msword";
      DOC3 = "application\/vnd\.ms-word.*";
      XLS = "application\/vnd\.ms-excel.*";
      PPT = "application\/vnd\.ms-powerpoint.*";
      GEN2 = "application\/vnd\.openxmlformats-officedocument.*";
    }
    # Mime-Part filename extension matching (no regex)
    mime_parts_filter_ext {
      doc = "doc";
      dot = "dot";
      docx = "docx";
      dotx = "dotx";
      docm = "docm";
      dotm = "dotm";
      xls = "xls";
      xlt = "xlt";
      xla = "xla";
      xlsx = "xlsx";
      xltx = "xltx";
      xlsm = "xlsm";
      xltm = "xltm";
      xlam = "xlam";
      xlsb = "xlsb";
      ppt = "ppt";
      pot = "pot";
      pps = "pps";
      ppa = "ppa";
      pptx = "pptx";
      potx = "potx";
      ppsx = "ppsx";
      ppam = "ppam";
      pptm = "pptm";
      potm = "potm";
      ppsm = "ppsm";
    }
    # `whitelist` points to a map of IP addresses. Mail from these addresses is not scanned.
    whitelist = "/etc/rspamd/antivirus.wl";
  }
  dcc {
    # If set force this action if any virus is found (default unset: no action is forced)
    # action = "reject";
    # If set, then rejection message is set to this value (mention single quotes)
    # If `max_size` is set, messages > n bytes in size are not scanned
    max_size = 20000000;
    #servers = "127.0.0.1:10045;
    # if `patterns` is specified virus name will be matched against provided regexes and the related
    # symbol will be yielded if a match is found. If no match is found, default symbol is yielded.
    patterns {
      # symbol_name = "pattern";
      JUST_EICAR = "^Eicar-Test-Signature$";
    }
    # `whitelist` points to a map of IP addresses. Mail from these addresses is not scanned.
    whitelist = "/etc/rspamd/antivirus.wl";
  }
}
]])
  return
end


local function add_scanner_rule(sym, opts)
  if not opts['type'] then
    rspamd_logger.errx(rspamd_config, 'unknown type for external scanner rule %s', sym)
    return nil
  end

  if not opts['symbol'] then opts['symbol'] = sym:upper() end
  local cfg = lua_scanners[opts['type']]

  if not cfg then
    rspamd_logger.errx(rspamd_config, 'unknown external scanner type: %s',
        opts['type'])
    return nil
  end

  if not opts['symbol_fail'] then
    opts['symbol_fail'] = string.upper(opts['type']) .. '_FAIL'
  end

  local rule = cfg.configure(opts)
  rule.type = opts.type
  rule.symbol_fail = opts.symbol_fail
  rule.redis_params = redis_params

  if not rule then
    rspamd_logger.errx(rspamd_config, 'cannot configure %s for %s',
      opts['type'], opts['symbol'])
    return nil
  end

  -- if any mime_part filter defined, do not scan all attachments
  if opts.mime_parts_filter_regex ~= nil
    or opts.mime_parts_filter_ext ~= nil then
      rule.scan_all_mime_parts = false
  end

  rule.patterns = common.create_regex_table(task, opts.patterns or {})

  rule.mime_parts_filter_regex = common.create_regex_table(task, opts.mime_parts_filter_regex or {})

  rule.mime_parts_filter_ext = common.create_regex_table(task, opts.mime_parts_filter_ext or {})

  if opts['whitelist'] then
    rule['whitelist'] = rspamd_config:add_hash_map(opts['whitelist'])
  end

  return function(task)
    if rule.scan_mime_parts then

      fun.each(function(p)
        local content = p:get_content()
        if content and #content > 0 then
          cfg.check(task, content, p:get_digest(), rule)
        end
      end, common.check_parts_match(task, rule))

    else
      cfg.check(task, task:get_content(), task:get_digest(), rule)
    end
  end
end

-- Registration
local opts = rspamd_config:get_all_opt(N)
if opts and type(opts) == 'table' then
  redis_params = rspamd_parse_redis_server(N)
  local has_valid = false
  for k, m in pairs(opts) do
    if type(m) == 'table' and m.servers then
      if not m.type then m.type = k end
      if not m.name then m.name = k end
      local cb = add_scanner_rule(k, m)

      if not cb then
        rspamd_logger.errx(rspamd_config, 'cannot add rule: "' .. k .. '"')
      else
        local id = rspamd_config:register_symbol({
          type = 'normal',
          name = m['symbol'],
          callback = cb,
          score = 0.0,
          group = N
        })
        rspamd_config:register_symbol({
          type = 'virtual',
          name = m['symbol_fail'],
          parent = id,
          score = 0.0,
          group = N
        })
        has_valid = true
        if type(m['patterns']) == 'table' then
          if m['patterns'][1] then
            for _, p in ipairs(m['patterns']) do
              if type(p) == 'table' then
                for sym in pairs(p) do
                  rspamd_logger.debugm(N, rspamd_config, 'registering: %1', {
                    type = 'virtual',
                    name = sym,
                    parent = m['symbol'],
                    parent_id = id,
                  })
                  rspamd_config:register_symbol({
                    type = 'virtual',
                    name = sym,
                    parent = id,
                    group = N
                  })
                end
              end
            end
          else
            for sym in pairs(m['patterns']) do
              rspamd_config:register_symbol({
                type = 'virtual',
                name = sym,
                parent = id,
                group = N
              })
            end
          end
        end
        if m['score'] then
          -- Register metric symbol
          local description = 'external services symbol'
          local group = N
          if m['description'] then
            description = m['description']
          end
          if m['group'] then
            group = m['group']
          end
          rspamd_config:set_metric_symbol({
            name = m['symbol'],
            score = m['score'],
            description = description,
            group = group
          })
        end
      end
    end
  end

  if not has_valid then
    lua_util.disable_module(N, 'config')
  end
end
