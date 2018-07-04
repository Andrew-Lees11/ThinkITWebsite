import Foundation
import Kitura
import LoggerAPI
import Configuration
import CloudEnvironment
import KituraContracts
import Health
import SwiftKueryORM
import SwiftKueryPostgreSQL
import KituraStencil

public let projectPath = ConfigurationManager.BasePath.project.path
public let health = Health()
extension Donation: Model {

}
class Persistence {
    static func setUp() {
        // If running locally use your own database url here
        if let databaseURL = ProcessInfo.processInfo.environment["databaseURL"], let url = URL(string: databaseURL) {
            let pool = PostgreSQLConnection.createPool(url: url, poolOptions: ConnectionPoolOptions(initialCapacity: 1, maxCapacity: 4, timeout: 10000))
            Database.default = Database(pool)
        } else {
            print("Couldn't get databaseURL envar. creating local database")
            let pool = PostgreSQLConnection.createPool(host: "localhost", port: 5432, options: [.databaseName("school")], poolOptions: ConnectionPoolOptions(initialCapacity: 10, maxCapacity: 50, timeout: 10000))
            Database.default = Database(pool)
        }
    }
}
public class App {
    let router = Router()
    let cloudEnv = CloudEnv()

    public init() throws {
        // Run the metrics initializer
        initializeMetrics(router: router)
    }

    func postInit() throws {
        // Middleware
        let sfsOptions = StaticFileServer.Options(possibleExtensions: ["html"])
        router.get("/teams", middleware: StaticFileServer(options: sfsOptions))
        router.all("/", middleware: StaticFileServer(path: "./public", options: sfsOptions))
        router.add(templateEngine: StencilTemplateEngine())
        // Endpoints
        initializeHealthRoutes(app: self)
        Persistence.setUp()
        do {
            try Donation.createTableSync()
        } catch let error {
            print(error)
        }
        router.post("/input", handler: donationHandler)
        router.post("/authinput", handler: authDonationHandler)
        router.get("/toggle", handler: toggleHandler)
        router.get("/scores") { request, response, next in
            guard !hideScores else {
                try response.render("hide.stencil", context: [:])
                return next()
            }
            if donationList.isEmpty {
                Donation.findAll { donations, error in
                    guard let donations = donations else {
                        return
                    }
                    donationList = donations
                    self.renderDonations(response: response, donations: donationList)
                    return next()
                }
            } else {
                self.renderDonations(response: response, donations: donationList)
                return next()
            }
        }
        
        router.get("/alldonations") { request, response, next in
            var context: [String: [[String:Any]]] = ["donations": []]
            for donation in donationList {
                context["donations"]?.append(["team": donation.team, "user": donation.username, "amount": donation.amount])
            }
            var teamScores = [String: Double]()
            for donation in donationList {
                teamScores[donation.team] = donation.amount + (teamScores[donation.team] ?? 0)
            }
            for team in teams {
                context["donations"]?.append(["team": team, "user": "ScoresTotal", "amount": String(teamScores[team] ?? 0)])
            }
            do {
                try response.render("alldonations.stencil", context: context)
            } catch {
                print("failed to render alldonations stencil")
            }
            next()
        }

        router.get("/") { request, response, next in
            let context: [String: Any] = ["teams": teams]
            print("teams context: \(context)")
            try response.render("teams.stencil", context: context)
            next()
        }

        router.get("/donators") { request, response, next in
            print("request query parameters: \(request.queryParameters)")
            guard var donatorName = request.queryParameters["donator"]?.lowercased() else {
                try response.render("seeDonations.stencil", context: [:]).end()
                return
            }
            if donatorName.hasPrefix("@") {
                donatorName = String(donatorName.dropFirst())
            }
            let requestDonator = "tweets/\(donatorName)"
            var donator = Donator(username: requestDonator, donations: [:])
            var totalDonations: Double = 0
            for donation in donationList {
                if donation.username.lowercased() == requestDonator {
                    donator.donations[donation.team] = donation.amount + (donator.donations[donation.team] ?? 0)
                    totalDonations = totalDonations + donation.amount
                }
            }
            var context: [String:Any] = ["donator": donatorName]
            print("context: \(context)")
            var tempTeams: [[String:Any]] = []
            for (index, team) in teams.enumerated() {
                tempTeams.append(["team": team, "amount": donator.donations[team] ?? 0, "index": index])
            }
            context["teams"] = tempTeams
            context["totalDonations"] = totalDonations
            print("donator context: \(context)")
            do {
                try response.render("donator.stencil", context: context)
            } catch {
                print("failed to render stencil")
            }
            next()
        }

    }

    func donationHandler(donation: Donation, completion: @escaping (DonationMessage?, RequestError?) -> Void) {
        print("recieved donation: \(donation)")
        if testing {
            donationList.append(donation)
            donation.save({ (donation, error) in
                guard let donation = donation else {
                    return completion(nil, error)
                }
                return completion(DonationMessage(donation: donation), nil)
            })
        }
    }
    
    func authDonationHandler(auth: MyBasicAuth, donation: Donation, completion: @escaping (DonationMessage?, RequestError?) -> Void) {
        if !testing {
            print("recieved donation: \(donation) from \(donation.username)")
            if donationList.isEmpty {
                
            } else {
                let existingUser = donationList.filter({$0.username == donation.username})
                let totalDonations = existingUser.map({ $0.amount }).reduce(0, +)
                if donation.username == unlimitedUser || totalDonations + donation.amount <= userCap {
                    donationList.append(donation)
                } else if totalDonations < userCap {
                    let adjustedDonation = Donation(username: donation.username, team: donation.team, amount: userCap - totalDonations)
                    donationList.append(adjustedDonation)
                }
            }
            Donation.findAll() { allDonations, error in
                let existingUser = allDonations?.filter({$0.username == donation.username})
                let totalDonations = existingUser?.map({ $0.amount }).reduce(0, +) ?? 0
                if donation.username == unlimitedUser || totalDonations + donation.amount <= userCap {
                    print("saved full donation: \(donation)")
                    donation.save({ (donation, error) in
                        guard let donation = donation else {
                            return completion(nil, error)
                        }
                        return completion(DonationMessage(donation: donation), nil)
                    })
                } else if totalDonations < userCap {
                    let adjustedDonation = Donation(username: donation.username, team: donation.team, amount: userCap - totalDonations)
                    print("saved partial donation: \(adjustedDonation)")
                    adjustedDonation.save({ (donation, error) in
                        guard let donation = donation else {
                            return completion(nil, error)
                        }
                        return completion(DonationMessage(donation: donation), nil)
                    })
                } else {
                    print("Donator out of money: \(donation)")
                    completion(DonationMessage(message: "Failed! Donator has no more funds."), nil)
                }
            }
        }
    }
    
    func toggleHandler(toggle: ToggleQuery, completion: @escaping (ToggleQuery?, RequestError?) -> Void) {
        if toggle.token == ProcessInfo.processInfo.environment["toggleToken"] {
            if let hide = toggle.hide {
                hideScores = hide
            }
            if let newLimit = toggle.nolimit {
                testing = newLimit
            }
            if toggle.clear == true {
                donationList = []
            }
            completion(toggle, nil)
        } else {
            completion(nil, .unauthorized)
        }
    }
    
    func renderDonations(response: RouterResponse, donations: [Donation]) {
        var teamScores = [String: Double]()
        for donation in donations {
            teamScores[donation.team] = donation.amount + (teamScores[donation.team] ?? 0)
        }
        var context: [String: [[String:Any]]] = ["donations" :[]]
        for team in teams {
            context["donations"]?.append(["team": team, "amount": String(teamScores[team] ?? 0)])
        }
        print("scores context: \(context)")
        do {
            try response.render("scores.stencil", context: context)
        } catch {
            print("failed to render stencil")
        }
    }

    public func run() throws {
        try postInit()
        Kitura.addHTTPServer(onPort: cloudEnv.port, with: router)
        Kitura.run()
    }

}
