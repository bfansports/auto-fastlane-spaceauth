require "aws-sdk"
require "aws-sdk-sqs"
require 'pry'

sqs = Aws::SQS::Client.new

# Retrieve SMS containing 2FA code from the API
# message_body = poller.poll.body
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

puts message_body #TODO: remove this line
binding.pry #TODO: remove this line

# Parse a 2FA code from the SMS body
code = message_body[/\d{6}/]
if code.nil? || code.empty?
    raise "NotFoundError"
end

# Enter the code
puts code

# Cleanup the SQS queue
sqs.delete_message({
    queue_url: ENV["SQS_QUEUE_URL"],
    receipt_handle: message.receipt_handle,
})