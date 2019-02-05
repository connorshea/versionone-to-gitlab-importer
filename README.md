# VersionOne to GitLab Issues Importer

This is a Ruby script I wrote to facilitate moving between a project 'backlog' in VersionOne and issues in GitLab. It should cover most major properties you'd want to import from VersionOne tickets. I've tried to comment it well and make it somewhat flexible. Hopefully it's useful to someone!

## Tested with

This script is only tested to work on macOS/Linux. Running it on Windows may work, but it wasn't tested.

- Ruby 2.6 (December 2018)
- `gitlab` gem v4.9.0 (February 2019, GitLab API v4)
- GitLab Community Edition v11.7.4 (January 2019)

Note: The script may work with different versions of the above software, but there are no guarantees. Ruby 2.5 should almost definitely work. It _should_ work with GitLab Enterprise Edition/GitLab.com as well, assuming they're on the same or similar version number.

## Data that is imported

The script maps the following data between VersionOne and GitLab Issues:

- Titles are mapped to titles
- Descriptions are mapped to descriptions
  - Images in descriptions will not be imported properly.
  - There are some small formatting issues with descriptions.
  - Tasks and tests belonging to the ticket are included in the description with their VersionOne title, description, and ID. They're rendered as a task list.
- Owners are mapped to assignees
  - Note that, because the script was written for use with Community Edition, multiple assignees are not supported. Only the first owner will be imported. The script should be relatively easy to update if you want to support multiple assignees (please open an issue with your code if you do update the script to make this happen!).
- Sprints are mapped to Milestones
- Priorities are mapped to "Low Priority", "Medium Priority", and "High Priority" Labels
- Backlog Groups are mapped to Labels with the same name as the Backlog Group
- Statuses are mapped to whether the issue is open/closed
  - A lack of Status and "In Progress" are both mapped to "Open", "Done" and "Accepted are mapped to "Closed".
  - An issue is also marked "Closed" if it has anything in the "Closed by" column.
- Time tracking data ("Todo Hrs." and "Done Hrs.") are mapped to time tracking in GitLab issues.
- "Create Date" is mapped to the creation date (VersionOne doesn't track specific times, just dates, so it's just set to midnight UTC on the day VersionOne gives. If you need to guarantee the dates are always accurate and never off by a day (GitLab renders dates in your local timezone, so if you're west of UTC you'll get the day before the actual creation date), you'll need to modify the code.)
  - Note that in order to create issues with a modified creation date you'll need to either be an Owner on the project or need to be an Admin of the GitLab instance.

All labels and milestones will be created for the project, users need to be created in GitLab before running the script, and the VersionOne users need to be mapped manually to their respective usernames in GitLab (see the instructions for more info).

All data from the CSV will be included in the description behind an HTML `<details>` element (collapsed by default) regardless of whether it's listed above. The only exceptions to this are for descriptions (due to descriptions frequently having linebreaks) and for task metadata. Only main ticket metadata is included.

## Instructions

**NOTE**: Before running this on the actual project, I would _strongly_ recommend you use a test project in GitLab to make sure the script is working properly for you. (Also keep in mind if the project is public or has any users in it, they can/will get emails for imported issues.) You can also test it by setting `create_issues` to false in the config near the top of the script. This will cause the script to output the VersionOne issue data and the GitLab issue data into the terminal, but not create any of the actual issues. (It will still create milestones, however!).

1. Clone this repository with `git clone https://github.com/connorshea/versionone-to-gitlab-importer`.
1. Install Ruby, preferably v2.6.x but other versions will probably work.
1. If you're not on Bundler 2.x (`bundle --version`), install Bundler 2.0.1 with `gem install bundler:2.0.1`. (You can probably use any version from the 2.x series.)
1. Install the necessary Ruby gems using `bundle install`.
1. In VersionOne:
   - If you'd like to include closed issues, check "Show Closed Items" in the search filter.
   - If you'd like to include tasks and tests, check "Show Tasks and Tests" in the search filter.
   - Add all necessary data to the view by going to the issue list, clicking on the wrench icon, and then "Customize". A popup window will open that will let you customize the data shown in the issue list. You'll want the following columns (order doesn't matter, if you have any extra columns that also doesn't matter (extra columns will still be included in the description in a `<details>` tag) so long as all of these are present):
     - ID
     - Title
     - Description
     - Owner
     - Backlog Group
     - Priority
     - Sprint
     - Status
     - Closed By, if you want to include closed issues.
     - Closed Date
     - Create Date
     - Todo Hrs. and Done Hrs, if you want to import time tracking data.
1. Now open the wrench menu again and click "Export (.xls)", this will create an Excel spreadsheet with all this data.
1. Open the `.xls` file you've downloaded in Excel, or any compatible spreadsheet tool, and then save/export it as a CSV (use UTF-8 formatting if you can). See [versionone-example.csv](versionone-example.csv) for an example of what the exported CSV file might look like.
1. Near the top of the `versionone-to-gitlab.rb` Ruby script, modify the `@config` and `@name_hash` variables as needed. The file has comments that should tell you what to put in these variables. If you don't know what you're doing, _don't edit anything below the big warning comment_. If you do know what you're doing, have fun!
1. Change the `@name_hash` variable in the script such that every key is the user's name in VersionOne and every value is their username on GitLab (the key/value looks like this on each line: `'key': 'value'`). You'll need to manually list everyone who has worked on your project for the owners to be imported properly, and only the first owner will be imported into GitLab Issues.
1. Set the following environment variables when you run the script, e.g. `GITLAB_PRIVATE_TOKEN=abc123456 ruby versionone-to-gitlab.rb`:
   - You can also set the environment variables in your command line separately so you don't need to enter the info multiple times.
   - `GITLAB_PRIVATE_TOKEN`: Your Personal Access Token (more info: https://docs.gitlab.com/ce/user/profile/personal_access_tokens.html, it'll need API permissions)
   - `GITLAB_API_URL` (default is `https://gitlab.com/api/v4`): The v4 API URL for your GitLab instance.
   - `GITLAB_PROJECT_ID`: The GitLab "Project ID" number, should be available on the project's home page in GitLab.
   - `VERSIONONE_CSV`: The name of the VersionOne CSV file you exported from Excel.
1. Run the script with something like this: `GITLAB_PRIVATE_TOKEN=xxxxx GITLAB_API_URL=https://example.com/api/v4 GITLAB_PROJECT_ID=123 VERSIONONE_CSV=versionone.csv ruby versionone-to-gitlab.rb`, or just `ruby versionone-to-gitlab.rb` if you've set the environment variables separately.

## License

This script is licensed under the terms of the [MIT License](https://opensource.org/licenses/MIT), see [LICENSE](LICENSE).
