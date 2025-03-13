import Foundation
import Logging
import NIOCore
import NIOPosix
import PostgresNIO

@Observable
class PostgresService {
    private var eventLoopGroup: EventLoopGroup?
    private var connection: PostgresConnection?

    var isConnected: Bool = false
    var connectionError: String?

    func connect(host: String, port: Int, username: String, password: String, database: String)
        async
    {
        // Close existing connection if any
        await self.disconnect()

        do {
            // Create a new event loop group
            let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.eventLoopGroup = elg

            // Connect to PostgreSQL
            self.connection = try await PostgresConnection.connect(
                on: elg.next(),
                configuration: PostgresConnection.Configuration(
                    host: host,
                    port: port,
                    username: username,
                    password: password,
                    database: database,
                    tls: .disable
                ),
                id: .min,
                logger: Logger(label: "postgres")
            )

            self.isConnected = true
            self.connectionError = nil
        } catch {
            self.isConnected = false
            self.connectionError = error.localizedDescription
            print("PostgreSQL connection error: \(error)")
        }
    }

    func disconnect() async {
        if let connection = self.connection {
            try? await connection.close()
            self.connection = nil
        }

        if let elg = self.eventLoopGroup {
            try? await elg.shutdownGracefully()
            self.eventLoopGroup = nil
        }

        self.isConnected = false
    }

    func fetchPriceData(forMarketId marketId: String, startDate: Date, endDate: Date) async throws
        -> [PriceData]
    {
        guard let connection = self.connection else {
            throw PostgresError.connectionClosed
        }

        let query = """
        SELECT
            date_trunc('second', block_time) AS time_second,
            AVG(quote_amount::numeric / NULLIF(base_amount, 0)::numeric) AS avg_price_in_sol,
            COUNT(*) AS transaction_count,
            MIN(quote_amount::numeric / NULLIF(base_amount, 0)::numeric) AS min_price_in_sol,
            MAX(quote_amount::numeric / NULLIF(base_amount, 0)::numeric) AS max_price_in_sol
        FROM swap_event
        WHERE base_address = $1
            AND block_time >= $2
            AND block_time < $3
        GROUP BY date_trunc('second', block_time)
        ORDER BY time_second
        """

        let rows = try connection.query(
            query,
            [
                PostgresData(string: marketId),
                PostgresData(date: startDate),
                PostgresData(date: endDate),
            ]
        ).wait()

        var priceData: [PriceData] = []

        for row in rows {
            if let timeSecond = row.column("time_second"), // 2025-02-25 17:40:46 +0000
               let avgPrice = row.column("avg_price_in_sol")?.double,
               let transactionCount = row.column("transaction_count")?.int,
               let minPrice = row.column("min_price_in_sol")?.double,
               let maxPrice = row.column("max_price_in_sol")?.double
            {
                let pricePoint = PriceData(
                    timeSecond: timeSecond.date ?? Date(),
                    avgPriceInSol: avgPrice,
                    transactionCount: transactionCount,
                    minPriceInSol: minPrice,
                    maxPriceInSol: maxPrice
                )

                priceData.append(pricePoint)
            }
        }

        return priceData
    }
}

enum PostgresError: Error {
    case connectionClosed
    case queryFailed(String)
}
