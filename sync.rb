#!/usr/bin/env ruby

require "json"
require "base64"
require "digest"
require "yaml"

def run(command)
  puts command
  fail "command error" unless system(command)
end

def run_output(command)
  puts command
  `#{command}`.tap do |out|
    fail "empty output" if out == ""
  end
end

# creates a note in the given folder
def create_note(name, notes, folder)
  data = {
    "object": "item",
    "folderId": folder,
    "type": 2,
    "name": name,
    "notes": notes,
    "secureNote": { "type": 0 }
  }

  string = Base64.encode64(JSON.pretty_generate(data)).split("\n").join

  JSON.parse(run_output("bw create item #{string}"))
end

def update_item(item)
  string = Base64.encode64(JSON.pretty_generate(item)).split("\n").join

  JSON.parse(run_output("bw edit item #{item["id"]} #{string}"))
end

fail "missing config.yaml" unless File.exists? "config.yaml"
allow_list = YAML.load_file("config.yaml")["allow_list"]

status = JSON.parse(run_output("bw status"))

fail "vault is locked" if status["status"] != "unlocked"

run("bw sync")

# get existing configs
config_folder = JSON.parse(run_output("bw list folders")).
  find { |f| f["name"] == "config" }
fail "config folder missing" if config_folder.nil?
config_folder_id = config_folder["id"]
configs = JSON.parse(run_output("bw list items --folderid #{config_folder_id}"))

# get local configs
base_path = "~/Code/"
current = run_output("find #{base_path} -maxdepth 2 | grep \"/\\(.envrc\\|config.yaml\\|\\w*\.conf\\)$\"").split("\n")
current.select! { |i| allow_list.any? { |j| i.include?(j) } }

current_content = Hash.new("")
current.each do |file|
  key = file.split("/")[4..-1].join("/")
  current_content[key] = file
end

# reconcile
current_content.each do |file, path|
  hash = Digest::SHA256.file(path).hexdigest
  content = File.read(path)

  item = configs.find { |c| c["name"] == file }
  if item.nil?
    if content.length > 10000
      item = create_note(file, "", config_folder_id)
    else
      item = create_note(file, content, config_folder_id)
    end
  end

  if content.length > 10000
    next if (item["fields"] || []).any? { |e| e["name"] == "attachment_hash" && e["value"] == hash }
    item["fields"] = [
      {
        name: "attachment_hash",
        value: hash,
        type: 0,
      }
    ]

    # clear any existing attachments
    basename = path.split("/").last
    (item["attachments"] || []).each do |attachment|
      if attachment["fileName"] == basename
        run("bw delete attachment #{attachment["id"]} --itemid #{item["id"]}")
      end
    end

    # create new attachment
    item["attachments"] =
      [run("bw create attachment --file #{path} --itemid #{item["id"]}")]
  else
    next if item["notes"] == content
    item["notes"] = content
  end

  # update the item hash
  update_item(item)
end
