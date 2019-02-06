require 'csv'
require 'gitlab'
require 'date'

# Configuration settings that can change the behavior of the script.
@config = {
  # Set this to false when testing, to make sure issues aren't actually created.
  # Milestones will still be created regardless.
  create_items: false,
  # Set this to false if you're getting SSL errors (generally avoid setting this to false if you can).
  ssl_verification: true,
  # Set a "VersionOne import" label by default for all imported issues.
  default_labels: ['VersionOne Import']
}

# A hash of names that is used to map between a user's name in VersionOne
# and a username in GitLab. Unfortunately there's not a great way to do this
# automatically, so you'll need to do it manually.
@name_hash = {
  'Connor Shea': 'connorshea',
  'John Doe': 'johndoe',
  'Jane Doe': 'janedoe'
}

#############################################
#############################################
####   ONLY EDIT DATA ABOVE THIS BLOCK   ####
#### (unless you know what you're doing) ####
#############################################
#############################################

# Your GitLab instance's API URL. Generally this is your instance domain plus `/api/v4`.
API_URL = ENV['GITLAB_API_URL'] || "https://gitlab.com/api/v4"
# Your private token, it needs to have enough privileges to create issues, milestones, and labels in the target project.
PRIVATE_TOKEN = ENV['GITLAB_PRIVATE_TOKEN']
# GitLab "Project ID", should be available on the project home page in GitLab.
PROJECT_ID = ENV['GITLAB_PROJECT_ID']
# CSV has to be in the same directory.
CSV_FILE_NAME = ENV['VERSIONONE_CSV']

# Create the GitLab client we'll be interacting with the API from.
@gitlab = Gitlab.client(
  endpoint: API_URL,
  private_token: PRIVATE_TOKEN,
  httparty: { verify: @config[:ssl_verification] }
)

# Duplicate the name_hash so when we modify it, so it won't lose any data.
@new_name_hash = @name_hash.dup

# Get GitLab user IDs from each user in @name_hash.
@name_hash.each do |key, value|
  # Search for a user based on the username provided in the name hash.
  user = @gitlab.user_search(value).first
  # If we can't find a user, skip this name.
  next if user.nil?
  user = user.to_hash
  # Set the value for each property in the hash to their GitLab user id, 
  # the User id is necessary for the API since it doesn't accept usernames.
  @new_name_hash[key] = user["id"] 
end

@name_hash = @new_name_hash

# Convert from a name to the id via the @name_hash.
def name_converter(name)
  return @name_hash[:"#{name}"]
end

@milestones = {}

# Create a milestone for each unique sprint in the issues array.
def create_milestones(issues)
  # Create a list of issues with unique sprint names.
  uniq_issues = issues.uniq { |issue| issue[:sprint] }
  # Create an array of sprint names.
  sprints = uniq_issues.map { |issue| issue[:sprint] }
  # Remove any empty strings.
  sprints = sprints.reject { |sprint| sprint.nil? || sprint.empty? }

  # Iterate through each sprint name in the array.
  sprints.each do |sprint|
    # Search for all existing milestones in the project with the same name as the current sprint.
    existing_milestones = @gitlab.milestones(PROJECT_ID, options: { search: "#{sprint}" } )

    # Create a list of existing milestones.
    existing_milestones_array = []
    existing_milestones.auto_paginate do |_milestone|
      existing_milestones_array << _milestone.to_hash
    end

    # Select any milestone with the same title as the current sprint.
    existing_sprint = existing_milestones_array.select do |_milestone|
      next(_milestone.to_hash["title"] == sprint)
    end

    # If the search returned any milestone with the same title as the current
    # sprint, set the milestone variable to that Milestone object.
    if !existing_sprint.empty?
      milestone = existing_sprint.first.to_hash
    # Otherwise, create a new milestone with the given sprint's name.
    else
      milestone = @gitlab.create_milestone(PROJECT_ID, "#{sprint}")
      milestone = milestone.to_hash
    end

    # Map between the sprint name and milestone id in GitLab.
    @milestones["#{sprint}"] = milestone["id"]
  end
end

# Truncate long strings to a max of 100 characters.
# Only used for printing to the console while running the script.
def truncate(s, length = 100, ellipsis = '...')
  if s.length > length
    s.to_s[0..length].gsub(/[^\w]\w+\s*$/, ellipsis)
  else
    s
  end
end

# Print metadata for the VersionOne ticket and the GitLab issue.
# Used for the command line interface when running the script.
def print_issue_metadata(issue, gitlab_hash, issue_title)
  puts
  puts "------"
  puts
  puts "\e[4mVersionOne Issue Metadata:\e[24m"
  issue.each do |key, value|
    # For strings like the description, remove any linebreaks from the end
    # and truncate them to 100 characters.
    if value.is_a?(String)
      puts "\e[1m#{key.to_s}\e[22m: #{truncate(value).chomp}"
    else
      puts "\e[1m#{key.to_s}\e[22m: #{value}"
    end
  end
  puts
  puts "\e[4mGitLab Issue Metadata:\e[24m"
  puts "\e[1mtitle\e[22m: #{issue_title}"
  gitlab_hash.each do |key, value|
    # For strings like the description, remove any linebreaks from the end
    # and truncate them to 100 characters.
    if value.is_a?(String)
      puts "\e[1m#{key.to_s}\e[22m: #{truncate(value).chomp}"
    else
      puts "\e[1m#{key.to_s}\e[22m: #{value}"
    end
  end
end

# Humanize time into a format that GitLab accepts.
# Inputs an integer or float and returns a time in the format of "3h30m".
# Examples:
# 1.00 => 1h
# 1.50 => 1h30m
# 0.50 => 30m
# 1 => 1h
# 25.00 => 25h
# 1.25 => 1h15m
# 
# Note that GitLab will auto-convert values of 8h to 1d in their interface (it assumes a standard 9-5 work day).
# e.g. 9h => 1d1h, 20h => 2d4h.
def humanize_time(time)
  if time % 1 == 0
    return "#{time.floor}h"
  elsif time < 1
    return "#{(time * 60).floor}m"
  else
    return "#{time.floor}h#{((time % 1) * 60).floor}m"
  end
end

# Create an empty array of rows to fill with the CSV data.
rows = []

# Scan the supplied CSV and create an array of row hashes.
CSV.foreach(
  File.join(File.dirname(__FILE__), CSV_FILE_NAME),
  skip_blanks: true,
  headers: true,
  header_converters: :symbol,
  encoding: 'bom|utf-8'
) do |row|
  rows << row
end

# Track the most recent ticket.
most_recent_parent_item = nil

# Iterate through each row to add task information to each row.
# The CSV is organized such that the tickets always come before their associated
# tasks, so we can make some assumptions about how the tickets and tasks are associated.
rows.each_with_index do |row, index|
  # Identify rows which are tasks.
  if row[:title].nil?
    row[:title] = row[1]
    row[:task] = true
  else
    row[:task] = false
  end

  # Delete nil data.
  row.delete_if { |key, value| key.nil? }

  if row[:task]
    row[:parent_item] = most_recent_parent_item
  else
    most_recent_parent_item = index
  end

  rows[index] = row
end

# Create an empty array of issues so we can fill it after parsing the rows.
issues = []

missing_labels = []

# Iterate through each row to create issue hashes.
rows.each_with_index do |row, index|
  # Skip the row if it represents a task
  next if row[:task]

  # Add the closing date to the issue description if the issue has a closed_date value.
  description = row[:closed_date].nil? ? "**VersionOne ID: #{row[:id]}**\n\n#{row[:description]}" : "**VersionOne ID: #{row[:id]}**\n\n**Closed date**: #{row[:closed_date]}\n\n#{row[:description]}"

  # Create a hash with various properties from the CSV columns.
  issue = {
    id: row[:id],
    title: row[:title],
    priority: row[:priority],
    description: description,
    sprint: row[:sprint],
    status: row[:status],
    backlog_group: row[:backlog_group],
    closed_by: row[:closed_by],
    create_date: row[:create_date],
    done_hrs: row[:done_hrs],
    todo_hrs: row[:to_do_hrs]
  }

  # Convert the issue owner to their user id, this only allows the first owner
  # to be assigned because GitLab CE doesn't support multiple assignees.
  issue[:owner] = name_converter(row[:owner].split(',').first) unless row[:owner].nil?

  # Filter the rows to child tasks of the current issue.
  tasks = rows.select { |row| row[:parent_item] == index }
  # If the current issue has any child tasks, render them in the description.
  if tasks.length > 0
    issue[:description] += "\n\n### Tasks and Tests"
    tasks.each do |task|
      # Determine whether the checkbox should be checked based on the task status.
      if task[:status] == "Accepted" || task[:status] == "Completed" || task[:status] == "Done"
        completed = "x"
      else
        completed = " "
      end

      # Add the task to the current issue description
      issue[:description] += "\n- [#{completed}] **#{task[:id]}**: #{task[:title]}"
      # Add the task description in a code block if the task has a description.
      unless task[:description].nil? || task[:description] == ""
        issue[:description] += "\n```\n#{task[:description]}\n```"
      end
    end
  end

  # Add VersionOne metadata in a details tag at the bottom of the description.
  issue[:description] += "\n<details>\n<summary>VersionOne Issue Metadata</summary>\n"
  row.each do |key, value|
    # Exclude the description and task data, and columns with no name
    unless key == :description || key == :task || key.nil?
      issue[:description] += "\n- #{key.to_s}: #{value}"
    end
  end
  issue[:description] += "\n</details>"

  # Strip any unknown characters from the descriptions.
  issue[:description] = issue[:description].force_encoding('utf-8').tr("\uFFFD", " ") unless issue[:description].nil?

  # Push the issue hash into the issues array.
  issues << issue
end

# Pass the issues array we created to the create_milestones method.
# This will create an @milestones variable.
create_milestones(issues)

puts "Creating #{issues.length} issues..."
# Iterate over each issue and map VersionOne issue attributes to their
# GitLab counterparts.
issues.each do |issue|
  gitlab_hash = {}

  # Map the description to the description
  gitlab_hash[:description] = issue[:description] unless issue[:description].nil?
  # Map the first owner to the assignee, GitLab CE only supports one assignee.
  gitlab_hash[:assignee_ids] = [issue[:owner]] unless issue[:owner].nil?
  # Map sprints to milestones
  gitlab_hash[:milestone_id] = @milestones[issue[:sprint].gsub(/Sprint ([A-Z])/, 'Sprint 17\1')] unless issue[:sprint].nil?
  # Set a custom creation date.
  gitlab_hash[:created_at] = DateTime.strptime(issue[:create_date], '%m/%d/%y').iso8601 unless issue[:create_date].nil?

  labels = []
  # Map Priority information to Low/Medium/High Priority labels
  labels << "#{issue[:priority]} Priority" unless issue[:priority].nil?
  # Add a label of the same time if the issue was in a backlog group
  labels << "#{issue[:backlog_group]}" unless issue[:backlog_group].nil?
  # Add custom labels if there are any
  unless @config[:default_labels].length == 0
    @config[:default_labels].each do |label|
      labels << label
    end
  end

  # Create a string with each label seprated by a comma, if there's more than one.
  gitlab_hash[:labels] = labels.join(',') unless labels.empty?

  if issue[:title].nil? || issue[:title].empty?
    issue_title = issue[:id]
  else
    issue_title = issue[:title]
  end

  # Create the issue using the options defined above.
  if @config[:create_items]
    print_issue_metadata(issue, gitlab_hash, issue_title)

    # Create the issue.
    gitlab_issue = @gitlab.create_issue(
      PROJECT_ID,
      issue_title,
      gitlab_hash
    )

    # Translate Todo Hrs and Done Hrs in VersionOne to time tracking info in GitLab.
    # If both todo_hrs and done_hrs are nil, skip handling time tracking for this issue.
    if (issue[:todo_hrs] || issue[:done_hrs])
      # If either todo_hrs or done_hrs are nil, replace them with 0.
      issue[:todo_hrs] = 0 if issue[:todo_hrs].nil?
      issue[:done_hrs] = 0 if issue[:done_hrs].nil?

      # Convert to a float if the time value is a String.
      issue[:todo_hrs] = issue[:todo_hrs].to_f if issue[:todo_hrs].is_a?(String)
      issue[:done_hrs] = issue[:done_hrs].to_f if issue[:done_hrs].is_a?(String)

      # The time estimate is the total todo_hrs plus the done_hrs.
      time_estimate = issue[:todo_hrs] + issue[:done_hrs]
      # The time spent is the total done_hrs.
      time_spent = issue[:done_hrs]
      
      @gitlab.estimate_time_of_issue(PROJECT_ID, gitlab_issue.to_h['iid'], humanize_time(time_estimate)) unless time_estimate == 0 || time_estimate.nil?
      @gitlab.add_time_spent_on_issue(PROJECT_ID, gitlab_issue.to_h['iid'], humanize_time(time_spent)) unless time_spent == 0 || time_spent.nil?
    end

    # If the issue is marked as "Done", "Accepted", or has been closed in VersionOne, close it.
    if (issue[:status] == "Done" || issue[:status] == "Accepted" || !issue[:closed_by].nil?)
      @gitlab.close_issue(PROJECT_ID, gitlab_issue.to_h['iid'])
    end

  # For testing purposes, print metadata if the create_items config
  # option is set to false.
  elsif !@config[:create_items]
    print_issue_metadata(issue, gitlab_hash, issue_title)
  end
end

puts
puts "------"
puts "Created #{issues.length} issues."
puts "Created #{@milestones.length} milestones."
