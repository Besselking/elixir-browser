import Config

# The resolver level for every parsed script: :off (the default), :info, or 1 to 4.
# See `Browser.JS.Resolve`. The parse option `resolve:` overrides it.
# config :browser, js_resolve: :off

import_config "#{config_env()}.exs"
