require 'sinatra'
require 'httparty'
require 'json'
require 'redis'
require 'celluloid/autostart'
require 'dotenv'
Dotenv.load unless ENV['RACK_ENV'] == 'production'

ENV['WORKER_KEY'] ||= 'test'
puts "WORKER_KEY is #{ENV['WORKER_KEY']}"

if !ENV['REDISCLOUD_URL'].nil?
	puts "Connecting to #{redis_connection_string}"
	uri = URI.parse(ENV["REDISCLOUD_URL"])
	$redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
else
	puts "connecting to local redis"
	$redis = Redis.new
end

class UOFindPeople
	def self.search(search_name)
		# for a search name string, return an **array** of matching names from UO Find People
		# cache searches in redis
		hash_key = "uo_student_cache_v1"
		if $redis.hexists(hash_key, search_name)
			result = JSON.parse $redis.hget(hash_key, search_name)
			puts "UOFindPeople cache HIT for '#{search_name}': #{JSON.generate(result)}"
		else
			result = JSON.parse( 
				HTTParty.get("http://uoregon.edu/findpeople/autocomplete/person/#{search_name.gsub(' ', '%20')}") 
			).map{|k, v| k }
			puts "UOFindPeople cache MISS for '#{search_name}': #{JSON.generate(result)}"
			$redis.hset(hash_key, search_name, JSON.generate(result))
		end
		result 
	end
end

class MergeData
	include Celluloid
	def perform
		puts "MergeData runs, but does nothing."
	end
end

class JailViewer

	include Celluloid
	
	def inmate_request_xml(date_string)
		%Q{<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><SearchBooking xmlns="http://tempuri.org/"><pLastName></pLastName><pFirstName></pFirstName><pBookingFromDate>#{date_string}T00:00:00</pBookingFromDate><pBookingFromto>#{date_string}T00:00:00</pBookingFromto><pReleasedFromDate>0001-01-01T00:00:00</pReleasedFromDate><pReleasedFromTo>0001-01-01T00:00:00</pReleasedFromTo><pCustody>ALL</pCustody><pIncludeDOB>false</pIncludeDOB></SearchBooking></s:Body></s:Envelope>}
	end
	
	def get_inmates(date_string)
		# date_string should be 'YYYY-MM-DD'
		inmates = HTTParty.post(
			'http://inmateinformation.lanecounty.org/PublicJailViewerServer.svc',
			body: inmate_request_xml(date_string),
			headers: {
				"Content-Type" => "text/xml; charset=utf-8",
				"SOAPAction"   => "http://tempuri.org/IPublicJailViewerServer/SearchBooking"
			}
		).to_h["Envelope"]["Body"]["SearchBookingResponse"]["SearchBookingResult"]["clsBooking"]
		$redis.set('latest_inmate_data', JSON.generate({time: Time.now.utc.to_i, data: inmates}))
		inmates
	end

	def update(num_days_back=1)
		puts "Starting update() for #{num_days_back} days back"
		date_strings = ((Date.today-num_days_back)..(Date.today+1)).map{|d| d.strftime }

		date_strings.each do |date_string|
			puts "Downloading inmates booked on #{date_string}"
			get_inmates(date_string).each do |inmate|	
				
				booking_number = inmate['BookingNumber']
				booking_date_utc_seconds = DateTime.parse("#{inmate['BookingDate']} Pacific Time").to_time.utc.to_i				

				$redis.hset("inmate_by_booking_number", booking_number, JSON.generate(inmate))				
				$redis.zadd("bookings_by_booking_date", booking_date_utc_seconds, booking_number)

				name = "#{inmate['FirstName']} #{inmate['LastName']}"
				puts name
				results = UOFindPeople.search(name) # blocking
				puts results.count
				puts results
				puts " " 
			end

			sleep 1.0 + rand() # be a little nice
		end

		MergeData.new.async.perform()
	end

end


get "/worker/:#{ENV['WORKER_KEY']}" do
	JailViewer.new.async.update((params[:num_days_back] || 1).to_i)
end

get '/latest.json' do
	content_type 'application/json'
	$redis.get('latest_inmate_data')
end

get '/' do
	#$redis.get('index_html')
	data = $redis.hgetall('inmate_by_booking_number').map{|k, v|
		inmate = JSON.parse(v)
		inmate.merge({
			'UOSearch' => JSON.parse($redis.hget('uo_student_cache_v1',"#{inmate['FirstName']} #{inmate['LastName']}"))
		})
	}.sort_by{|record|
		record['BookingDate']
	}.reverse
	erb :index, locals: { data: data }
end

get '/inmate/:booking_number' do
	$redis.hget('inmate_by_booking_number', params['booking_number'])
end

get '/uo_cache' do
	["<pre>",
	JSON.pretty_generate(
		$redis.hgetall('uo_student_cache_v1').map{|k, v|
			{ search: k, results: JSON.parse(v) }
		}.sort_by{|record|
			-record[:results].length
		}
	),
	"</pre>"].join("")
end
