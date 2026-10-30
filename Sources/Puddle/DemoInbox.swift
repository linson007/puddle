import Foundation
import PuddleCore

enum DemoInbox {
    static var messages: [MailMessage] {
        [
            MailMessage(id: "demo-design", subject: "A few thoughts before Friday’s review", sender: "Maya Chen <maya@example.test>",
                        date: Date().addingTimeInterval(-900), snippet: "The updated designs are ready. Could you share your feedback by Thursday?",
                        body: "Hi there,\n\nThe updated Puddle designs are ready for Friday’s review at 10:00 AM.\n\nCould you share feedback on the inbox layout by Thursday afternoon? I’ve focused on keeping new mail easy to spot and the reading view distraction-free.\n\nThanks,\nMaya", labels: ["INBOX", "UNREAD", "IMPORTANT"]),
            MailMessage(id: "demo-receipt", subject: "Your October workspace receipt", sender: "Studio North <billing@example.test>",
                        date: Date().addingTimeInterval(-7200), snippet: "Payment received. Your receipt is attached for your records.",
                        body: "Your October workspace payment of ₹4,500 was received on October 28.\n\nYour next billing date is November 28. No action is needed.\n\nA receipt is attached for your records.", labels: ["INBOX"], attachments: ["october-receipt.pdf"]),
            MailMessage(id: "demo-walk", subject: "Saturday morning?", sender: "Sam Rivera <sam@example.test>",
                        date: Date().addingTimeInterval(-14400), snippet: "Fancy a walk by the lake at 8? We can grab breakfast after.",
                        body: "Hey!\n\nFancy a walk by the lake this Saturday at 8:00 AM? We can grab breakfast after. Let me know if that works.\n\nSam", labels: ["INBOX", "UNREAD"]),
        ]
    }
    static var arrival: MailMessage {
        MailMessage(id: "demo-new-\(UUID().uuidString)", subject: "The local inbox check worked", sender: "Puddle Demo <hello@example.test>",
                    snippet: "This sample message arrived after the initial sync.",
                    body: "This is a simulated new message. Puddle detected it after the first inbox sync and marked it New.\n\nReal Gmail checks use the same merge and new-message detection logic.", labels: ["INBOX", "UNREAD"])
    }
    static func summary(for message: MailMessage) -> String {
        switch message.id {
        case "demo-design": return "• Friday’s design review is at 10:00 AM.\n• Maya asks for inbox-layout feedback by Thursday afternoon.\n• Action: review the layout and prepare your feedback."
        case "demo-receipt": return "• The October workspace payment of ₹4,500 was received.\n• Next billing date: November 28.\n• A receipt is attached; its contents have not been read.\n• No action is requested."
        case "demo-walk": return "• Sam suggests a lake walk on Saturday at 8:00 AM, followed by breakfast.\n• Action: let Sam know whether you can make it."
        default: return "• A simulated new email arrived after the initial sync.\n• Puddle detected it and marked it New."
        }
    }
}
