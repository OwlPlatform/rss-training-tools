################################################################################
# This tool fetches signal maps that were created with the
# gen_reverse_signal_map.rb tool and prints them out so that they can be plotted
# on a figure or viewed in file viewer.
################################################################################

require 'rubygems'
require 'client_world_connection.rb'
require 'wm_data.rb'
require 'buffer_manip.rb'

def shutdown()
  puts "Exiting..."
  if (@cwc != nil and @cwc.connected)
    @cwc.close()
  end
  exit
end

if ARGV.length != 2
  puts "This solver requires 2 arguments:"
  puts "\t<wm IP> <wm client port>"
  puts "The program prints the transmitter x, y, (possibly z,)"
  puts "receiver x, y, (possibly z,) RSS, delta RSS, transmitter name, and area URI"
  puts "values of training points taken with the gen reverse signal map points tool"
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
#Use a snapshot request to get the map points
################################################################################

#Map between receivers and names
@rx_to_training = {}

def storeSignals(wmdata)
  if (wmdata.ticket == 1)
    rss_vec = []
    name_vec = []
    location = []
    creation = 0
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
      @rx_to_training[name].push "#{location.join(' ')} #{rss} #{creation} #{name}"
    }
  end
end

#Now connect as a client
@cwc = ClientWorldConnection.new(wm_ip, client_port)
if (not @cwc.connected())
  puts "Failed to connect to the world model as a client."
  shutdown()
end

#Prefer locations set by people
@m2_origin = "grail/localization_solver\nversion 1.0\nAlgorithm M2"

class Anchor
  attr_accessor :name, :offsets, :origins

  def initialize(name)
    @name = name
    @offsets = Array.new(3)
    @origins = Array.new(3, "")
  end

  def setOffset(name, value, origin)
    axis = name[9,1]
    coord = {'x' => 0, 'y' => 1, 'z' => 2}[axis]
    if (@origins[coord] == "" or @origins[coord] == @m2_origin)
      @offsets[coord] = value
      @origins[coord] = origin
    end
  end
end

#Get transmitter locations
tx_names = @cwc.snapshotRequest(".*\\.anchor\\..*", ['sensor.*', 'location\..offset']).get()

#Get signal map
signal_maps = @cwc.snapshotRequest(".*\\.signal map\\..*", ['transmitter.uri', 'fingerprint\.vector<RSS>', 'fingerprint\.vector<location\..offset>']).get()

#Now close the client connection
@cwc.close()

anchors = {}
tx_names.each {|anchor, locations|
  if (not anchors.has_key? anchor)
    anchors[anchor] = Anchor.new(anchor)
  end
  locations.each {|attr|
    if (attr.name[0, 8] == "location")
      anchors[anchor].setOffset(attr.name, attr.data.unpack('G')[0], attr.origin)
    end
  }
}

#Now print out signal map values
signal_maps.each {|uri, attributes|
  tx_uri = ''
  locations = []
  rss_vals = []
  attributes.each{|attribute|
    #Find which Anchor this corresponds to
    if (attribute.name == 'transmitter.uri')
      tx_uri = readUnsizedUTF16(attribute.data)
    elsif (attribute.name == 'fingerprint.vector<RSS>')
      rss_vals = attribute.data.unpack('@4G*')
    else
      #fingerprint.vector<location.?offset>
      axis = attribute.name[28,1]
      coord = {'x' => 0, 'y' => 1, 'z' => 2}
      locations[coord[axis]] = attribute.data.unpack('@4G*')
    end
  }
  if (anchors.has_key? tx_uri)
    prev_rss = nil
    tx_coords = anchors[tx_uri].offsets
    dimensions = locations.length
    rss_vals.each_index{|i|
      line = ""
      (0..(dimensions-1)).each{|d|
        line += "#{tx_coords[d]} "
      }
      (0..(dimensions-1)).each{|d|
        line += "#{locations[d][i]} "
      }
      line += "#{rss_vals[i]} "
      if (prev_rss == nil)
        line += "nil "
      else
        line += "#{(rss_vals[i] - prev_rss).abs} "
      end
      prev_rss = rss_vals[i]
      puts "#{line}#{tx_uri.split(' ').join('_')} #{uri.split(' ').join('_')}"
    }
  end
}

