require "json"
require "pty"
require "expect"
require "fastlane"
require "spaceship"
require "aws-sdk"
require "aws-sdk-sqs"
require "aws-sdk-secretsmanager"

# In the environment we need:
# SQS_QUEUE_URL - URL of the SQS queue to receive SMS messages from Apple
# SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER - Phone number to receive 2FA code (the AWS Pinpoint phone number)
# FASTLANE_USER - Apple ID
# FASTLANE_PASSWORD - Apple ID password
# SESSION_MANAGER_SECRET_ID - AWS Secrets Manager secret ID to store the FASTLANE_SESSION

# Borrowed from https://blog.kishikawakatsumi.com/entry/2021/01/28/074522
# Modified to work with AWS
def fastlane_spaceauth(fastlane_session = "")
  $expect_verbose = true

  # Run the `fastlane spaceauth` command using PTY to respond to 2FA input
  unless fastlane_session.empty?
    ENV["FASTLANE_SESSION"] = fastlane_session
  end
  ENV["FASTLANE_DISABLE_COLORS"] = "1" # Clean up the logs
  cmd = "bundle exec fastlane spaceauth"
  PTY.spawn(cmd) do |r, w|
    w.sync = true

    # If there is a valid session cookie, return it
    r.expect(/FASTLANE_SESSION='(.+)'/, 10) do |match|
      if match
        return match[1]
      end
    end

    # If the session is invalid and need to enter the 2FA code
    r.expect(/Please enter the 6 digit code you received at .+:/, 60) do |match|
      raise "UnknownError" unless match

      # Retrieve SMS containing 2FA code from the API
      sqs = Aws::SQS::Client.new
      messages = sqs.receive_message({
        queue_url: ENV["SQS_QUEUE_URL"],
        max_number_of_messages: 1,
        wait_time_seconds: 20,
      })
      if messages.messages.empty?
        raise "NotFoundError"
      end
      message = messages.messages[0]
      message_body = JSON.parse(JSON.parse(message.body)["Message"])["messageBody"]

      puts message_body

      # Parse a 2FA code from the SMS body
      code = message_body[/\d{6}/]
      if code.nil? || code.empty?
        raise "NotFoundError"
      end

      # Enter the code
      w.puts code

      # Cleanup the SQS queue
      sqs.delete_message({
        queue_url: ENV["SQS_QUEUE_URL"],
        receipt_handle: message.receipt_handle,
      })
    end

    r.expect(/FASTLANE_SESSION='(.+)'/, 10) do |match|
      raise "UnknownError" unless match
      return match[1]
    end

  end
end

# Gets the FASTLANE_SESSION from AWS Secrets Manager.
def get_previously_saved_session()
  client = Aws::SecretsManager::Client.new()
  resp = client.get_secret_value({
    secret_id: ENV["SESSION_MANAGER_SECRET_ID"]
  })
  secrets = JSON.parse(resp.secret_string)
  session = secrets['FASTLANE_SESSION']
  puts "Successfully got the FASTLANE_SESSION from AWS Secrets Manager."
  return session
end

# Updates the FASTLANE_SESSION in AWS Secrets Manager.
def save_session(fastlane_session = "")
  client = Aws::SecretsManager::Client.new()
  resp = client.get_secret_value({
    secret_id: ENV["SESSION_MANAGER_SECRET_ID"]
  })
  secrets = JSON.parse(resp.secret_string)
  secrets['FASTLANE_SESSION'] = fastlane_session
  client.put_secret_value({
    secret_id: resp.arn,
    secret_string:  JSON.generate(secrets)
  })
  puts "Successfully set the FASTLANE_SESSION in AWS Secrets Manager."
end

def lambda_handler(event:, context:)
  previous_fastlane_session = get_previously_saved_session()
  new_fastlane_session = fastlane_spaceauth(previous_fastlane_session)
  puts # Add a new line to the output for readability
  if new_fastlane_session != previous_fastlane_session
    save_session(new_fastlane_session)
    puts "Session updated"
  else
    puts "Session is still valid"
  end

  return {
      FASTLANE_SESSION: new_fastlane_session,
  }
end