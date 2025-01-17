# gslash-server: Server-side portion for Geometry Slash
# Copyright (C) 2021 Andrew Pirie <twosecslater@snopyta.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

require "db"
require "sqlite3"
require "kemal"
require "csv"

db_path, schema_path = "./gslash.db", "./schema"

Log.setup_from_env

Kemal.config.extra_options do |opts|
  opts.on "-d PATH", "--database PATH", "Path to sqlite database (defaults to '#{db_path}')" do |path|
    db_path = path
  end
  opts.on "-c PATH", "--schema PATH", "Path to database schemas (defaults to '#{schema_path}')" do |path|
    schema_path = path
  end
end

Kemal::CLI.new ARGV

db = DB.open URI.new("sqlite3", path: db_path, query: "foreign_keys=on")

def get_uid(db : DB::Database, uname : String) : Int32
  db.query_one("SELECT uid FROM players WHERE uname=(?)", uname, as: {Int32})
end

# Check if tables exist, and if not, create them
["players", "scores"].each do |table|
  begin
    db.exec "SELECT * FROM #{table} LIMIT 0"
  rescue
    db.exec File.read("#{schema_path}/#{table}.sql")
    Log.info { "created table #{table}" }
  end
end

before_all do |env|
  env.response.headers["Source"] = "https://github.com/2secslater/gslash-server.git"
end

post "/submit" do |env|
  username = env.params.body["username"].as(String)
  # sqlite doesn't enforce character limit
  # we block commas to keep CSV client-side code simple
  if username.size > 16 || username.includes?(',')
    env.response.status_code = 400
    next
  end
  score = env.params.body["score"].to_u32
  # get uid for username, probably a better way to do this
  begin
    uid = get_uid db, username
  rescue
    db.exec "INSERT INTO players VALUES (NULL, ?)", username
  ensure
    uid ||= get_uid db, username
  end
  db.exec "INSERT INTO scores VALUES (NULL, ?, ?)", score.to_s, uid # converting score to string because sqlite and uint32
  env.response.status_code = 200
end

get "/top" do |env|
  env.response.headers["Content-Type"] = "text/csv"
  player = env.params.query["uname"]?
  if player
    score = db.query_one("SELECT score FROM scores WHERE player=(?) ORDER BY score DESC LIMIT 1", get_uid(db, player), as: {Int64})
    result = "#{player},#{score}"
  else
    from = env.params.query["from"]? || 0
    count = db.query_one("SELECT COUNT (*) FROM (SELECT player, MAX (score) FROM scores GROUP BY player)", as: {Int64}).to_s
    result = CSV.build do |csv|
      csv.row "count", count
      db.query "SELECT players.uname, MAX (score) FROM scores LEFT JOIN players ON scores.player = players.uid GROUP BY player ORDER BY score DESC LIMIT 50 OFFSET (?)", from.to_i32 do |row|
        row.each do
          csv.row row.read(String), row.read(Int64) # sqlite returns int64
        end
      end
    end
  end
  result
end

Kemal.config do |cfg|
  cfg.powered_by_header = false
  cfg.serve_static = false
  cfg.app_name = "gslash"
end
Kemal.run
