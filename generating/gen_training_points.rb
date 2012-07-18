################################################################################
# This tool creates training points from a transmitter moving along a known
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
  puts "The path file should have the region name on the first line, the transmitter physical"
  puts "layer and id on the second line (separated by a dot, ie 'phy.id'), and then subsequent"
  puts "lines should have the x and y or x, y, and z coordinates separated by a space."
  puts "The trace will be commited after the entire path is complete."
  puts "The frequencies that the transmitter operates on can also be specified on the same line"
  puts "as the transmitter phy and ID. For instance the line"
  puts "\t1.595 902100000 910100000"
  puts "specifies a transmitter on physical layer 1 with ID 595 that will transmit across"
  puts "902.1MHz and 910.1MHz (ie, each transmission at 902.1MHz will be immediately followed by"
  puts "a transmission at 910.1MHz)."
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
  @device_freq = file.gets
  if (@region == nil or
      @device_freq == nil)
      puts "File has no region or device! Aborting!"
      shutdown()
  end
  @region.chomp!
  @device_freq.chomp!
  @coordinates = []
  while (line = file.gets)
    parts = line.chomp.split(' ')
    vals = parts.map{|x| x.to_i}
    @coordinates.push(vals)
  end
}
#The phy and ID are the first value and the frequencies are all values that follow
@device = @device_freq.split(' ')[0]
@freqs = @device_freq.split(' ')[1..-1]
puts "Getting data in #{@region} with device #{@device}"
puts "There are #{@coordinates.length} coordinates"
if (@freqs != [])
  puts "Transmitter operates on frequencies #{@freqs}"
end

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
      #readUnsizedUTF16(attr.data)
      phy = attr.data.unpack('C')[0]
      id = unpackuint128(attr.data[1, attr.data.length])
      @rx_to_uri[id] = wmdata.uri
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
@cwm.sendSnapshotRequest(".*", ['sensor.*'], 1)

#Get the response
while (@cwm.handleMessage() != ClientWorldModel::REQUEST_COMPLETE)
  sleep 0.01
end

#Now close the client connection
@cwm.close()

puts "Found receivers: #{@rx_to_uri}"

################################################################################
#Now start requesting data from the aggregator for the desired target
#Store the data with timestamps but don't assign it to locations yet
################################################################################

#Sample class to hold data for each packet from the transmitting device
class Sample
  attr_accessor :time, :packets

  def initialize(time)
    @time = time
    @packets = []
  end

  #A packet at the given time belongs to this sample
  #if it occurs within 100 milliseconds of the last packet
  def belongs(pack_time)
    return (((@time - pack_time)).abs < 100)
  end

  def push(packet)
    @packets.push(packet)
  end
end

#Make a place to store the samples
@samples = []

#Store the samples differently if there are multiple frequencies
if (0 != @freqs.length)
  @freq_samples = []
  #@freq_samples.fill([], 0..(@freqs.length - 1))
  (1..@freqs.length).each{|x|
    @freq_samples.push([])
  }
end

puts "Connecting to the aggregator..."
@aggregator = SolverAggregator.new(agg_ip, agg_port)

#Request packets the physical layer and ID specified and request all
#packets by passing 0 as the packet interval. Store the packets so
#that they can be processed after the path is complete
#These are string masks so they must be padded to 16 characters
#tx_mask = [(@device.split('.')[1]).to_i.to_s(16).rjust(16, '0'), 'FFFFFFFFFFFFFFFF']
tx_mask = IDMask.new((@device.split('.')[1]).to_i)
rules = [AggrRule.new((@device.split('.')[0]).to_i, [tx_mask], 0)]
@aggregator.sendSubscription(rules)

#Keep getting samples while the user does their walk.
if (0 == @freqs.length)
  @data_thread = Thread.new do
    while (@aggregator.handleMessage) do
      if (@aggregator.available_packets.length != 0) then
        pack_time = getOctopusTime()
        puts "New packets at time #{pack_time}"
        if @samples.empty? or not @samples[-1].belongs(pack_time)
          @samples.push(Sample.new(pack_time))
        end
        #Store the packets for later consumption
        for packet in @aggregator.available_packets do
          @samples[-1].push(packet)
        end
        #Clear out the packets
        @aggregator.available_packets = []
      end
    end
  end
else
  rx_state_time = {}
  @data_thread = Thread.new do
    while (@aggregator.handleMessage) do
      if (@aggregator.available_packets.length != 0) then
        pack_time = getOctopusTime()
        puts "New packets at time #{pack_time}"
        #Store the packets for later consumption
        for packet in @aggregator.available_packets do
          #TODO FIXME The packet timestamp is unreliable, but using the local time
          #might group packets together that should not be grouped
          packet.timestamp = pack_time
          #Start on the first frequency at the current timestamp
          cur_freq = 0
          #If we already saw previous packets then set the current frequency based on that
          if (rx_state_time.has_key? packet.receiver_id)
            #puts "difference is #{packet.timestamp - rx_state_time[packet.receiver_id][0]}"
            diff = packet.timestamp - rx_state_time[packet.receiver_id][0]
            #Reset to first frequency if this is too far in the future
            if (diff > 10)
              cur_freq = 0
            else
              cur_freq = rx_state_time[packet.receiver_id][1]+1
            end
          end
          rx_state_time[packet.receiver_id] = [packet.timestamp, cur_freq]
          #puts "packet timestamp is #{packet.timestamp}"
          #puts "cur freq is #{cur_freq}"
          if @freq_samples[cur_freq].empty? or not @freq_samples[cur_freq][-1].belongs(pack_time)
            @freq_samples[cur_freq].push(Sample.new(pack_time))
          end
          @freq_samples[cur_freq][-1].push(packet)
        end
        #Clear out the packets
        @aggregator.available_packets = []
      end
    end
  end
end

##TODO FIXME HERE Need to add a frequency value to each URI and add the frequency (channel number) to the URI
@move_times = []
#Keep track of the current coordinate
@coordinates.each { |coord|
  puts "Press enter when you reach #{coord}"
  line = STDIN.gets
  @move_times.push(getOctopusTime())
  puts "Time is #{@move_times[-1]}"
}

Thread.kill(@data_thread)
puts "Data gathering is complete, now sending data to the world model..."

#Disconnect from the aggregator
@aggregator.close()


#Create solutions for each packet
#Training points should have the following attributes:
#URI with the name "training point" in it.
#Attributes:
#  location.xoffset
#  location.yoffset
#  location.zoffset (optional)
#  receivers.vector<sized string>
#  fingerprint.vector<RSS>
#  URI train_points = u".*\\.training point\\..*";
#  vector<URI> train_locations{u"location\\..offset", u"receivers\\.vector<sized string>", u"fingerprint\\.vector<RSS>"};

@base_name = @region + ".training point."
puts "All training points will start with name: #{@base_name}"
#The last part of the name will be the time the training point was taken

#First build the time intervals and point pairs
@intervals = @move_times.each_cons(2).zip(@coordinates.each_cons(2))

#Now build the world model data
@new_data = []

def write_samples(target_name)
  @intervals.each {|interval|
    tstart = interval[0][0]
    tstop = interval[0][1]
    duration = tstop - tstart
    coordstart = interval[1][0]
    coordstop = interval[1][1]
    coords = coordstart.zip(coordstop)
    #Drop samples that are too early
    @samples = @samples.drop_while{|i| i.time < tstart}
    #Grab samples for the current interval
    cur_samples = @samples.take_while{|i| i.time <= tstop}
    #Calculate the positon from the current time for each sample
    solutions = cur_samples.each {|sample|
      progress = (sample.time-tstart).to_f / duration

      interpolated_position = []
      coords[0].each_index{|i|
        interpolated_position.push(progress * (coords[1][i] - coords[0][i]) + coords[0][i])
      }
      #puts "#{sample.time} has progress #{progress} position #{interpolated_position.join(" ")}"
      #Make data for the world model if there is anything to push
      packets = sample.packets.select{|packet| @rx_to_uri.has_key?(packet.receiver_id)}
      #puts "Working with #{packets.length} packets"
      if (not packets.empty?)
        attribs = []
        #Store the x, y, and possibly z offsets
        domains = ['x', 'y', 'z']
        interpolated_position.each_index{|i|
          attribs.push WMAttribute.new("location.#{domains[i]}offset", [interpolated_position[i]].pack('G'), sample.time)
        }
        #Store the vectors of receiver IDs and RSS values
        #  receivers.vector<sized string>
        #  fingerprint.vector<RSS>
        rxer_vector = [packets.length].pack('N')
        rss_vector = [packets.length].pack('N')
        packets.each {|packet|
          rxuri = @rx_to_uri[packet.receiver_id]
          rxer_vector += strToSizedUTF16(rxuri)
          rss_vector += [packet.rssi].pack('G')
          puts "#{target_name}.#{@device}.#{packet.receiver_id} #{interpolated_position[0]} #{interpolated_position[1]} #{sample.time} #{packet.rssi}"
        }
        attribs.push WMAttribute.new("receivers.vector<sized string>", rxer_vector, sample.time)
        attribs.push WMAttribute.new("fingerprint.vector<RSS>", rss_vector, sample.time)
        @new_data.push(WMData.new("#{target_name}.#{@device}.#{sample.time}", attribs))
      end
    }
  }
end

if (0 == @freqs.length)
  #Only one frequency, just write the samples
  write_samples("#{@region}.training point")
else
  #Write samples for each frequency
  @freqs.each_index{|idx|
    @samples = @freq_samples[idx]
    puts "Processing at frequency #{idx} with #{@samples.length} samples"
    write_samples("#{@region}.training point.#{@freqs[idx]}")
  }
end

#Send the traces to the world model
puts "Connecting as a solver..."
swm = SolverWorldModel.new(wm_ip, solv_port, "training point collector\nversion 1.0")
if (not swm.connected)
 puts "Failed to connect to the world model as a solver."
 shutdown()
end
#Push the data and create new URIs for it
puts "Pushing #{@new_data.length} new solutions."
swm.pushData(@new_data, true)

shutdown()
