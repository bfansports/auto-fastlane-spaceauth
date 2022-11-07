require 'json'
require "pty"
require "expect"
require "fastlane"
require "spaceship"
require "aws-sdk"
require "aws-sdk-sqs"
require 'pry' # TODO - remove this line


# Borrowed from https://blog.kishikawakatsumi.com/entry/2021/01/28/074522
# Modified to work with AWS
def fastlane_spaceauth()
  $expect_verbose = true

  sqs = Aws::SQS::Client.new

  # Run the `fastlane spaceauth` command using PTY to respond to 2FA input
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
      binding.pry
      raise "UnknownError" unless match
      binding.pry
      return match[1]
    end

  end
end

# TODO: Activate this
# def lambda_handler(event:, context:)
#   session = fastlane_spaceauth()
# # TODO Send session to secrets manager

#   {
#     statusCode: 200,
#     body: {
#       message: "Hello World!",
#       # location: response.body
#     }.to_json
#   }
# end

# TODO remove this
begin
  session = fastlane_spaceauth()
  puts session
  binding.pry
rescue => e
  puts e
  binding.pry
end