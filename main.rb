$stdout.sync = true
$stderr.sync = true

require 'dotenv'
require 'json'
require 'time'
Dotenv.load(File.join(__dir__, '.env'))

require_relative 'sheet_manager'
require_relative 'mastodon_listener'

RUNNER_SHEET_ID   = ENV['RUNNER_SHEET_ID']
CREATURE_SHEET_ID = ENV['CREATURE_SHEET_ID']
VIEW_SHEET_ID     = ENV['VIEW_SHEET_ID']
CREDENTIALS_PATH  = File.join(__dir__, 'credentials.json')
ACTION_TIMEOUT    = 300

puts "[전투봇] 시작"

runner_sheet   = SheetManager.new(RUNNER_SHEET_ID, CREDENTIALS_PATH)
creature_sheet = SheetManager.new(CREATURE_SHEET_ID, CREDENTIALS_PATH)
view_sheet     = SheetManager.new(VIEW_SHEET_ID, CREDENTIALS_PATH)
listener       = MastodonListener.new(ENV['MASTODON_BASE_URL'], ENV['BATTLE_TOKEN'])

puts "[전투봇] 초기화 완료 - DM 대기 중"

loop do
  sleep(30)
end
