################################################################################
# This tool expires training point data given the time range of the points
# to expire.
################################################################################

require 'rubygems'
require 'client_world_model.rb'
require 'solver_world_model.rb'
require 'wm_data.rb'
require 'buffer_manip.rb'

def shutdown()
  puts "Exiting..."
  if (@cwm != nil and @cwm.connected)
    @cwm.close()
  end
  if (@swm != nil and @swm.connected)
    @swm.close()
  end
  exit
end

if ARGV.length != 5
  puts "This solver requires 5 arguments:"
  puts "\t<wm IP>  <wm solver port> <wm client port> <start time> <end time>"
  puts "Any training points taken between <start time> and <end time>"
  puts "(inclusive) will be expired."
  exit
end

wm_ip       = ARGV[0]
solver_port = ARGV[1]
client_port = ARGV[2]
@start_time = ARGV[3].to_i
@end_time   = ARGV[4].to_i

Signal.trap("SIGTERM") {
  shutdown()
}

Signal.trap("SIGINT") {
  shutdown()
}

def getOctopusTime()
  t = Time.now
  return t.tv_sec * 1000 + t.usec/10**3
end

################################################################################
#Use a snapshot request to get the training points
################################################################################

#Remember the URI names to expire
@uris = []

def rememberURIs(wmdata)
  if (wmdata.ticket == 1)
    if (wmdata.attributes.length > 0)
      time = wmdata.attributes[0].creation
      if (@start_time <= time and
          time <= @end_time)
          @uris.push(wmdata.uri)
      end
    end
  end
end

#Now connect as a client
@cwm = ClientWorldModel.new(wm_ip, client_port, method(:rememberURIs))
if (not @cwm.connected())
  puts "Failed to connect to the world model as a client."
  shutdown()
end

#Get sensor names
@cwm.sendSnapshotRequest(".*\.training point\..*", ['receivers\.vector<sized string>', 'fingerprint\.vector<RSS>', 'location\..offset'], 1)

#Get the response
while (@cwm.handleMessage() != ClientWorldModel::REQUEST_COMPLETE)
  sleep 0.01
end

#Expire the URIs
puts "Connecting as a solver..."
@swm = SolverWorldModel.new(wm_ip, solver_port, "training point collector\nversion 1.0")
if (not @swm.connected)
  puts "Failed to connect to the world model as a solver."
  shutdown()
end

expire_time = getOctopusTime()
@uris.each {|uri|
  @swm.expireURI(uri, expire_time)
}

