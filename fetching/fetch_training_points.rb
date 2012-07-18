################################################################################
# This tool fetches training points that were created with the
# gen_training_points.rb tool and prints them out so that they can be plotted
# on a figure or viewed in file viewer.
################################################################################

require 'rubygems'
require 'client_world_model.rb'
require 'wm_data.rb'
require 'buffer_manip.rb'

def shutdown()
  puts "Exiting..."
  if (@cwm != nil and @cwm.connected)
    @cwm.close()
  end
  exit
end

if ARGV.length != 2
  puts "This solver requires 2 arguments:"
  puts "\t<wm IP> <wm client port>"
  puts "The program prints the x, y, (possibly z,) RSS, sample time,"
  puts "and receiver ID (and then possibly frequency) values"
  puts "of training points taken with the gen_training_points tool"
  exit
end

wm_ip       = ARGV[0]
client_port = ARGV[1]

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

#Map between receivers and names
@rx_to_training = {}

def storeSignals(wmdata)
  if (wmdata.ticket == 1)
    rss_vec = []
    name_vec = []
    location = []
    creation = 0
    freq_string = ""
    #See if this sample came from a specific frequency
    if (nil != (wmdata.uri =~ /.*\.training point\.(.*)\..*\..*\..*/))
      freq_string = " #{$1}"
    end
    wmdata.attributes.each {|attr|
      if (attr.name == 'receivers.vector<sized string>')
        num = attr.data.unpack('N')[0]
        rest = attr.data[4, attr.data.length]
        (1..num).each {|i|
          rxname, rest = splitURIFromRest(rest)
          name_vec.push rxname
        }
      elsif (attr.name == 'fingerprint.vector<RSS>')
        num = attr.data.unpack('N')[0]
        rest = attr.data[4, attr.data.length]
        rss_vec = rest.unpack("G#{num}")
        creation = attr.creation
      elsif (attr.name == 'location.xoffset')
        location[0] = attr.data.unpack('G')[0]
      elsif (attr.name == 'location.yoffset')
        location[1] = attr.data.unpack('G')[0]
      elsif (attr.name == 'location.zoffset')
        location[2] = attr.data.unpack('G')[0]
      end
    }
    name_vec.each_index {|i|
      name = name_vec[i]
      rss = rss_vec[i]
      #Initialize entries to empty arrays
      if (not @rx_to_training.has_key?(name))
        @rx_to_training[name] = []
      end
      #Add in this location and RSS value to this receiver's data points
      @rx_to_training[name].push "#{location.join(' ')} #{rss} #{creation} #{name}#{freq_string}"
    }
  end
end

#Now connect as a client
@cwm = ClientWorldModel.new(wm_ip, client_port, method(:storeSignals))
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

#Now close the client connection
@cwm.close()

#Print out the entries for each receiver
@rx_to_training.each {|key, value|
  value.each{|entry|
    puts entry
  }
}

