################################################################################
# This tool stores signal maps from a receiver moving along a known
# path. RSS values are obtained from the aggregator and placed into the world
# model for the localization solver to use.
################################################################################

require 'rubygems'
require 'client_world_model.rb'
require 'solver_world_model.rb'
require 'wm_data.rb'
require 'buffer_manip.rb'
require 'solver_aggregator'

require 'thread'

def shutdown()
  puts "Exiting..."
  if (@cwm != nil and @cwm.connected)
    @cwm.close()
  end
  if (@swm != nil and @swm.connected)
    @swm.close()
  end
  if (@aggregator != nil and @aggregator.connected)
   @aggregator.close()
  end
  exit
end

if ARGV.length != 6
  puts "This solver requires 6 arguments:"
  puts "\t<aggregator IP> <aggregator port> <wm IP> <wm solver port> <wm client port> <path file>"
  puts "The path file should have the region name on the first line, the receiver physical"
  puts "layer and id on the second line (separated by a dot, ie 'phy.id'), and then subsequent"
  puts "lines should have the x and y or x, y, and z coordinates separated by a space."
  puts "The trace will be commited after the entire path is complete."
  exit
end

agg_ip   = ARGV[0]
agg_port = ARGV[1]
wm_ip       = ARGV[2]
solv_port   = ARGV[3]
client_port = ARGV[4]
file_name   = ARGV[5]

File.open(file_name, 'r') {|file|
  @region = file.gets
  @area = file.gets
  @device = file.gets
  if (@region == nil or
      @area == nil or
      @device == nil)
      puts "File has no region, area, or device! Aborting!"
      shutdown()
  end
  @region.chomp!
  @area.chomp!
  @device.chomp!
  @coordinates = []
  while (line = file.gets)
    parts = line.chomp.split(' ')
    vals = parts.map{|x| x.to_f}
    @coordinates.push(vals)
  end
}
puts "Getting data in #{@region} with device #{@device}"
puts "There are #{@coordinates.length} coordinates"

if (@coordinates.length > 0)
  @num_coordinates = @coordinates[0].length
end
puts "Gathering data for #{@num_coordinates} dimensions."

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
#First use a snapshot request to find the names of all receivers.
#Next request the transmitter's data from the aggregator.
#After that have the user press enter to start data collection and press
#enter at every turn and when data collection is complete.
#Put the fingerprints into the world model when data collection is done.
################################################################################

#Map between receivers and names
@rx_to_uri = {}

def rememberSensors(wmdata)
  if (wmdata.ticket == 1)
    wmdata.attributes.each {|attr|
      if (attr.name[0, 6] == 'sensor')
        #readUnsizedUTF16(attr.data)
        phy = attr.data.unpack('C')[0]
        id = unpackuint128(attr.data[1, attr.data.length])
        @rx_to_uri[id] = wmdata.uri
      end
    }
  end
end

#Now connect as a client
puts "Connecting as a client..."
@cwm = ClientWorldModel.new(wm_ip, client_port, method(:rememberSensors))
if (not @cwm.connected())
  puts "Failed to connect to the world model as a client."
  shutdown()
end

#Get sensor names
@cwm.sendSnapshotRequest(".*anchor.*", ['sensor.*', 'location\..offset'], 1)

#Get the response
while (@cwm.handleMessage() != ClientWorldModel::REQUEST_COMPLETE)
  sleep 0.01
end

#Now close the client connection
@cwm.close()

puts "Found radios: #{@rx_to_uri}"

################################################################################
#Now start requesting data from the aggregator for the desired target
#Store the data with timestamps but don't assign it to locations yet
################################################################################

#Sample class to hold data for each packet from the transmitting device
class Sample
  attr_accessor :time, :packet

  def initialize(pack_time, packet)
    @time = pack_time
    @packet = packet
  end
end

#Make a place to store the samples from each transmitter
@samples = {}

puts "Connecting to the aggregator..."
@aggregator = SolverAggregator.new(agg_ip, agg_port)

#Request packets the physical layer and ID specified and request all
#packets by passing 0 as the packet interval. Store the packets so
#that they can be processed after the path is complete
#These are string masks so they must be padded to 16 characters
#tx_mask = [(@device.split('.')[1]).to_i.to_s(16).rjust(16, '0'), 'FFFFFFFFFFFFFFFF']
#rx_mask = IDMask.new((@device.split('.')[1]).to_i)
#rules = [AggrRule.new((@device.split('.')[0]).to_i, [rx_mask], 0)]
#All new packets every 500 milliseconds
rules = [AggrRule.new((@device.split('.')[0]).to_i, [], 500)]
@aggregator.sendSubscription(rules)

@rx_id = @device.split('.')[1].to_i

#Keep getting samples while the user does their walk.
data_thread = Thread.new do
  while (@aggregator.handleMessage) do
    if (@aggregator.available_packets.length != 0) then
      pack_time = getOctopusTime()
      #Store the packets for later consumption
      for packet in @aggregator.available_packets do
        if (@rx_id == packet.receiver_id and @rx_to_uri.has_key? packet.device_id)
          if (not @samples.has_key? packet.device_id)
            @samples[packet.device_id] = []
          end
          @samples[packet.device_id].push(Sample.new(pack_time, packet))
        end
      end
      #Clear out the packets
      @aggregator.available_packets = []
    end
  end
end

@move_times = []
#Keep track of the current coordinate
@coordinates.each { |coord|
  puts "Press enter when you reach #{coord}"
  result = STDIN.gets
  @move_times.push(getOctopusTime())
  puts "Time is #{@move_times[-1]}"
}

Thread.kill(data_thread)
puts "Data gathering is complete, now sending data to the world model..."

#Disconnect from the aggregator
@aggregator.close()

puts "Got data from #{@samples.length} samples"


#Create solutions for each packet
#Training points should have the following attributes:
#URI with the name "signal point" in it.
#Attributes:
#  transmitter.sized_string
#  fingerprint.vector<location.xoffset>
#  fingerprint.vector<location.yoffset>
#  fingerprint.vector<location.zoffset> (optional)
#  fingerprint.vector<RSS>
#  URI train_points = u".*\\.signal map\\..*";
#  vector<URI> train_locations{u"fingerprint\\.vector<location.?offset>", u"fingerprint\\.vector<RSS>"};

@base_name = @region + ".signal map."
#The last part of the name will be the time the training point was taken

#First build the time intervals and point pairs
@intervals = @move_times.each_cons(2).zip(@coordinates.each_cons(2))

#Now build the world model data
@new_data = []

#Time for all of the solutions
soln_time = getOctopusTime();

#Build an entry for the signal map from each transmitter
@samples.each_pair {|tx_name, tx_samples|
  if (tx_samples.length > 5)
    puts "Txer #{tx_name} has #{tx_samples.length} samples"
    #Record the location and RSS value and location of each sample
    rss_vals = []
    locations = []
    tx_uri = @rx_to_uri[tx_name]
    @intervals.each {|interval|
      tstart = interval[0][0]
      tstop = interval[0][1]
      duration = tstop - tstart
      coordstart = interval[1][0]
      coordstop = interval[1][1]
      puts "Start and stop are #{coordstart} and #{coordstop}"
      coords = coordstart.zip(coordstop)
      #Now each index of coords corresponds to an axis
      #Each axis has two entries, for the beginning position and the end position.
      #Drop samples that are too early
      tx_samples = tx_samples.drop_while{|i| i.time < tstart}
      #Grab samples for the current interval
      cur_samples = tx_samples.take_while{|i| i.time <= tstop}
      #Calculate the positon from the current time for each sample
      puts "Interval has #{cur_samples.length} sample values"
      puts "Coords is #{coords}"
      cur_samples.each {|sample|
        progress = (sample.time-tstart).to_f / duration

        interpolated_position = []
        coordstart.each_index{|i|
          #Progress times the total travel distance + the starting position
          interpolated_position.push(progress * (coordstop[i] - coordstart[i]) + coordstart[i])
        }
        puts "Interpolated position is #{interpolated_position}"

        #Record the values of this packet
        rss_vals.push(sample.packet.rssi)
        interpolated_position.each_index{|i|
          if (locations[i] == nil)
            locations[i] = Array.new
          end
          locations[i].push(interpolated_position[i])
        }
      }
    }

    #These are the attributes we need to create
    #  transmitter.uri
    #  fingerprint.vector<location.xoffset>
    #  fingerprint.vector<location.yoffset>
    #  fingerprint.vector<location.zoffset> (optional)
    #  fingerprint.vector<RSS>
    #  URI train_points = u".*\\.signal map\\..*";
    #  vector<URI> train_locations{u"fingerprint\\.vector<location.?offset>", u"fingerprint\\.vector<RSS>"};
    #  receivers.vector<sized string>
    #  fingerprint.vector<RSS>

    if (not rss_vals.empty?)
      attributes = []
      soln_uri = "#{@region}.signal map.#{@area}.#{@device.split('.')[0]}.#{tx_name}"
      attributes.push WMAttribute.new("transmitter.uri", strToUnicode(@rx_to_uri[tx_name]), soln_time)

      #Store the vectors locations and RSS values
      rss_vector = [rss_vals.length].pack('N') + rss_vals.pack('G*')
      attributes.push WMAttribute.new("fingerprint.vector<RSS>", rss_vector, soln_time)

      #Store the x, y, and possibly z offsets
      domains = ['x', 'y', 'z']
      locations.each_index{|i|
        location_vector = [locations[i].length].pack('N') + locations[i].pack('G*')
        attributes.push WMAttribute.new("fingerprint.vector<location.#{domains[i]}offset>", location_vector, soln_time)
      }
      @new_data.push(WMData.new(soln_uri, attributes))
      #puts "Created data for #{soln_uri} (txer #{@rx_to_uri[tx_name]})with #{rss_vals.length} samples."
      #rss_vals.each_index{|i|
        #puts "\t#{locations[0][i]}, #{locations[1][i]}, #{rss_vals[i]}"
      #}
    end
  end
}

#Send the traces to the world model
puts "Connecting as a solver..."
swm = SolverWorldModel.new(wm_ip, solv_port, "signal map collector\nversion 1.0")
if (not swm.connected)
  puts "Failed to connect to the world model as a solver."
  shutdown()
end
#Push the data and create new URIs for it
puts "Pushing #{@new_data.length} new solutions."
swm.pushData(@new_data, true)

shutdown()
