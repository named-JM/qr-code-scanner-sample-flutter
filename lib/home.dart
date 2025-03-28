import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:qrqragain/Generate_QR_Code/qr_home.dart';
import 'package:qrqragain/Storage/inventory.dart';
import 'package:qrqragain/Treatment_Area/treatment_page.dart';
import 'package:qrqragain/constants.dart';
import 'package:qrqragain/login/create/login.dart';
import 'package:qrqragain/offline_db.dart';

class SyncService {
  static Future<void> syncPendingUpdates() async {
    var connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult == ConnectivityResult.none)
      return; // Skip if offline

    List<Map<String, dynamic>> updates =
        await LocalDatabase.getPendingUpdates();
    for (int i = 0; i < updates.length; i++) {
      var update = updates[i];
      var response = await http.post(
        Uri.parse('$BASE_URL/sync.php'),
        body: jsonEncode(update),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        LocalDatabase.deletePendingUpdate(i); // Remove after successful sync
      }
    }
  }
}

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool hasLowStock = false;
  List<dynamic> lowStockItems = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    syncOfflineUpdates();
    checkLowStock(); // Initial check for low stock

    // Ensure first API call after UI build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      checkLowStock();
    });

    _startAutoCheck(); // Start auto-refresh
  }

  @override
  void dispose() {
    _timer?.cancel(); // Stop timer when the widget is disposed
    super.dispose();
  }

  Future<void> syncOfflineUpdates() async {
    final pendingUpdatesBox = await Hive.openBox('pending_updates');
    final inventoryBox = await Hive.openBox('inventory');

    if (pendingUpdatesBox.isNotEmpty) {
      List<Map<String, dynamic>> updates = [];

      for (var item in pendingUpdatesBox.values) {
        updates.add({
          'qr_code_data': item['qr_code_data'],
          'quantity_removed': item['quantity_removed'] ?? 0,
          'quantity_added': item['quantity_added'] ?? 0,
        });
      }

      final response = await http.post(
        Uri.parse('$BASE_URL/sync_updates.php'),
        body: jsonEncode({'updates': updates}),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        if (result['success']) {
          for (var update in updates) {
            int index = inventoryBox.values.toList().indexWhere(
              (item) => item['qr_code_data'] == update['qr_code_data'],
            );

            if (index != -1) {
              var item = inventoryBox.getAt(index);
              item['quantity'] =
                  (item['quantity'] ?? 0) -
                  (update['quantity_removed'] ?? 0) +
                  (update['quantity_added'] ?? 0);
              inventoryBox.putAt(index, item);
            }
          }

          await pendingUpdatesBox.clear();

          // **Force UI Refresh**
          setState(() {});

          print("Offline updates synced successfully!");
        } else {
          print("Sync failed: ${result['message']}");
        }
      } else {
        print("Failed to sync offline updates.");
      }
    }
  }

  void _startAutoCheck() {
    _timer = Timer.periodic(Duration(seconds: 10), (timer) {
      checkLowStock();
    });
  }

  Future<void> checkLowStock() async {
    var connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult == ConnectivityResult.none) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('No internet connection.')));
      return;
    }

    try {
      final response = await http.get(Uri.parse("$BASE_URL/notif.php"));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        // Debugging: Print the API response
        //  print("API Response: ${response.body}");

        // Filter out items where status is "normal"
        List<dynamic> newItems =
            (data['items'] ?? [])
                .where(
                  (item) =>
                      item['statuses'] != null && item['statuses'].isNotEmpty,
                )
                .toList();

        if (mounted) {
          setState(() {
            lowStockItems = newItems;
            hasLowStock =
                newItems.isNotEmpty; // Update hasLowStock based on newItems
          });
        }
      } else {
        print("Failed to fetch data: ${response.statusCode}");
      }
    } catch (e) {
      print("Error fetching low stock data: $e");
    }
  }

  void showNotificationSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.4,
          padding: EdgeInsets.all(16.0),
          child: Column(
            children: [
              Text(
                hasLowStock ? "Low Stock / Expiry Alert!" : "All items are OK",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 25),
              if (hasLowStock)
                Expanded(
                  child: ListView(
                    children:
                        lowStockItems.expand((item) {
                          List<Widget> notifications = [];

                          for (var status in item['statuses']) {
                            notifications.add(
                              _buildNotificationTile(
                                itemName: item['item_name'],
                                quantity: item['quantity'],
                                expiry: item['exp_date'],
                                status: status,
                              ),
                            );
                          }

                          return notifications;
                        }).toList(),
                  ),
                )
              else
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text("All items are sufficiently stocked."),
                        SizedBox(height: 5),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text("Dismiss"),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // 🔹 Updated Helper Function for Multiple Statuses
  Widget _buildNotificationTile({
    required String itemName,
    required int quantity,
    required String? expiry,
    required String status,
  }) {
    IconData icon;
    Color iconColor;
    Color textColor;
    String statusText;

    switch (status) {
      case "low_stock":
        icon = Icons.warning;
        iconColor = Colors.red[800]!;
        textColor = Colors.red[900]!;
        statusText = "Low Stock (Critical)";
        break;
      case "warning":
        icon = Icons.event;
        iconColor = Colors.yellow[800]!;
        textColor = Colors.yellow[900]!;
        statusText = "3 months before expired";
        break;
      case "near_expiry":
        icon = Icons.event_available;
        iconColor = Colors.orange[800]!;
        textColor = Colors.orange[900]!;
        statusText = "Nearly Expired";
        break;
      case "expired":
        icon = Icons.event_busy;
        iconColor = Colors.red[800]!;
        textColor = Colors.red[900]!;
        statusText = "Expired";
        break;
      default:
        return SizedBox(); // Ignore "normal" status
    }

    return Card(
      color: Colors.white,
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Icon(icon, color: iconColor, size: 28),
        title: Text(
          itemName,
          style: TextStyle(fontWeight: FontWeight.bold, color: textColor),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              statusText,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Remaining: $quantity | Expiry: ${expiry ?? 'N/A'}',
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          "AIMS",
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        leading: Stack(
          children: [
            IconButton(
              icon: Stack(
                children: [
                  Icon(Icons.notifications, size: 30),
                  if (hasLowStock)
                    Positioned(
                      right: 3,
                      top: 3,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
              onPressed: () async {
                showNotificationSheet();
              },
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.logout, size: 30),
            onPressed: () {
              _showLogoutDialog(context);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                SizedBox(height: 60),
                Image.asset('assets/bulacan_logo.png', width: 250, height: 250),
                SizedBox(height: 50),
                Container(
                  width: double.infinity,
                  margin: EdgeInsets.symmetric(
                    horizontal: 16.0,
                  ), // Set margin on both sides

                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => InventoryPage(),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.lightGreen,
                      padding: EdgeInsets.symmetric(vertical: 16.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      textStyle: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    child: const Text('Storage'),
                  ),
                ),
                SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  margin: EdgeInsets.symmetric(
                    horizontal: 16.0,
                  ), // Set margin on both sides
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => TreatmentPage(),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.lightGreen,
                      padding: EdgeInsets.symmetric(vertical: 16.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      textStyle: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    child: const Text('Treatment Page'),
                  ),
                ),
                SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  margin: EdgeInsets.symmetric(
                    horizontal: 16.0,
                  ), // Set margin on both sides
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => QrHome()),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.lightGreen,
                      padding: EdgeInsets.symmetric(vertical: 16.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      textStyle: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    child: const Text('Generate QR Code'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text("Logout"),
          content: Text("Are you sure you want to log out?"),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (context) => LoginScreen()),
                  (Route<dynamic> route) => false,
                );
              },
              child: Text("Logout"),
            ),
          ],
        );
      },
    );
  }
}
