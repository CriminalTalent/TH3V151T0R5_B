# http_patch.rb
# HTTP gem의 응답 파싱 문제 최소한의 패치

require 'http'

module HTTP
  class Response
    class Body
      # encoding 메서드 추가
      def encoding
        Encoding::UTF_8
      end
    end
  end
end

puts "[HTTP Patch] 최소 패치 적용 완료"
