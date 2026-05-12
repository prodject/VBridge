import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            
            Image("AboutLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                .padding(.top, 40)
            
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .foregroundColor(.secondary)
            
            Divider()
                .padding(.horizontal, 40)
                .padding(.top, 10)
            
            VStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/prodject/VBridge")!) {
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 30)
                        
                        Text("GitHub Repository")
                            .font(.system(size: 16, weight: .medium))
                        
                        Spacer()
                        
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .foregroundColor(.primary)
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                }
                
                Link(destination: URL(string: "https://t.me/prodject")!) {
                    HStack {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18))
                            .frame(width: 30)
                        
                        Text("@prodject")
                            .font(.system(size: 16, weight: .medium))
                        
                        Spacer()
                        
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(red: 0.53, green: 0.37, blue: 0.98).opacity(0.75))
                    }
                    .foregroundColor(Color(red: 0.53, green: 0.37, blue: 0.98))
                    .padding()
                    .background(Color(red: 0.53, green: 0.37, blue: 0.98).opacity(0.1))
                    .cornerRadius(12)
                }

            }
            .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                Text("Thanks & Credits")
                    .font(.headline)
                    .padding(.horizontal, 40)

                VStack(spacing: 12) {
                    Link(destination: URL(string: "https://github.com/nullcstring/turnbridge")!) {
                        HStack {
                            Image(systemName: "heart.text.square.fill")
                                .font(.system(size: 18))
                                .frame(width: 30)
                            Text("nullcstring / turnbridge")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(.primary)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                    }

                    Link(destination: URL(string: "https://github.com/samosvalishe/turn-proxy-android")!) {
                        HStack {
                            Image(systemName: "heart.text.square.fill")
                                .font(.system(size: 18))
                                .frame(width: 30)
                            Text("samosvalishe / turn-proxy-android")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(.primary)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                    }

                    Link(destination: URL(string: "https://github.com/WINGS-N/WINGSV")!) {
                        HStack {
                            Image(systemName: "heart.text.square.fill")
                                .font(.system(size: 18))
                                .frame(width: 30)
                            Text("WINGS-N / WINGSV")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(.primary)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 40)
            }
            
            Spacer()
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
