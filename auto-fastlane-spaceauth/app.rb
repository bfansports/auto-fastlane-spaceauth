require "json"
require "fastlane"
require "spaceship"
require "aws-sdk-sqs"
require "aws-sdk-secretsmanager"

# In the environment we need:
# SQS_QUEUE_URL - URL of the SQS queue to receive SMS messages from Apple
# SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER - Phone number to receive 2FA code (the AWS Pinpoint phone number)
# FASTLANE_USER - Apple ID for Fastlane
# FASTLANE_PASSWORD - Apple ID password for Fastlane
# SECRETS_MANAGER_SECRET_ID - AWS Secrets Manager secret ID to store the FASTLANE_SESSION

# Overrides spaceship/lib/spaceship/two_step_or_factor_client.rb
class TwoFAInterceptorClient
  def ask_for_2fa_code
    puts "overrided"
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

    puts code

    # Cleanup the SQS queue
    sqs.delete_message({
      queue_url: ENV["SQS_QUEUE_URL"],
      receipt_handle: message.receipt_handle,
    })

    return code
  end
end

def fastlane_spaceauth(fastlane_session = "")
  # Run the `fastlane spaceauth` command using PTY to respond to 2FA input
  # Set the previous session in case it's still valid
  unless fastlane_session.empty?
    ENV["FASTLANE_SESSION"] = fastlane_session
  end
  # Clean up the logs
  ENV["FASTLANE_DISABLE_COLORS"] = "1"
  # Dark Magic
  Spaceship.Client.singleton_class.prepend(TwoFAInterceptorClient)
  # Let's go !
  fastlane_session = Spaceship::SpaceauthRunner.new(copy_to_clipboard: false).run.session_string
  # Done
  return fastlane_session
end

# Gets the FASTLANE_SESSION from AWS Secrets Manager.
def get_previously_saved_session()
  client = Aws::SecretsManager::Client.new()
  resp = client.get_secret_value({
    secret_id: ENV["SECRETS_MANAGER_SECRET_ID"]
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
    secret_id: ENV["SECRETS_MANAGER_SECRET_ID"]
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