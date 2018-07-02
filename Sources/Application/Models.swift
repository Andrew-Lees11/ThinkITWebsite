//
//  Models.swift
//  Application
//
//  Created by Andrew Lees on 30/04/2018.
//

import Foundation
import KituraContracts
import CredentialsHTTP

struct Donation: Codable {
    let username: String
    let team: String
    var amount: Double
}

struct DonationMessage: Codable {
    let message: String
    init(donation: Donation) {
        self.message = "Success!! Saved donation of \(donation.amount) from \(donation.username) for team \(donation.team)"
    }
    init(message: String) {
        self.message = message
    }
}

struct Donator {
    let username: String
    var donations = [String: Double]()
}

struct ToggleQuery: QueryParams, Codable {
    let token: String
    let hide: Bool?
    let nolimit: Bool?
}

public struct MyBasicAuth: TypeSafeHTTPBasic {
    public let id: String
}

extension MyBasicAuth {
    static let users = ["Andy" : ProcessInfo.processInfo.environment["toggleToken"]]
    
    public static func verifyPassword(username: String, password: String, callback: @escaping (MyBasicAuth?) -> Void) {
        if let storedPassword = users[username], storedPassword == password {
            callback(MyBasicAuth(id: username))
        } else {
            callback(nil)
        }
    }
}


let teams: [String] = ["Ada Lovelace", "Elizabeth Blackwell", "Grace Hopper", "Jane Goodall", "Katherine Johnson", "Mae Jemison", "Marie Curie", "Rosalind Franklin"]

let userCap: Double = 1000
let unlimitedUser: String? = ProcessInfo.processInfo.environment["unlimitedUser"]
var hideScores: Bool = false
var testing: Bool = true
var donationList: [Donation] = []

