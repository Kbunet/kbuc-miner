package net.kbunet.miner

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL = "net.kbunet.miner/notifications"
    
    companion object {
        const val MINING_COMPLETION_CHANNEL = "mining_completion_channel"
        const val MINING_PROGRESS_CHANNEL = "mining_progress_channel"
    }
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Create notification channels for Android O and above
        createNotificationChannels()
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "createNotificationChannels" -> {
                    createNotificationChannels()
                    result.success(true)
                }
                "showNotification" -> {
                    val title = call.argument<String>("title") ?: "Mining Notification"
                    val message = call.argument<String>("message") ?: "Mining task completed"
                    val notificationId = call.argument<Int>("notificationId") ?: 1
                    
                    showNotification(title, message, notificationId)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
    
    private fun showNotification(title: String, message: String, notificationId: Int) {
        try {
            val builder = NotificationCompat.Builder(this, MINING_COMPLETION_CHANNEL)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(message)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
            
            with(NotificationManagerCompat.from(this)) {
                try {
                    notify(notificationId, builder.build())
                    Log.d("MinerApp", "Notification shown: $title - $message")
                } catch (e: Exception) {
                    Log.e("MinerApp", "Error showing notification: ${e.message}")
                }
            }
        } catch (e: Exception) {
            Log.e("MinerApp", "Error creating notification: ${e.message}")
        }
    }
    
    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                // Create mining completion channel
                val miningCompletionChannel = NotificationChannel(
                    MINING_COMPLETION_CHANNEL,
                    "Mining Completion",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notifications for mining job completions"
                    enableLights(true)
                    enableVibration(true)
                }
                
                // Create mining progress channel
                val miningProgressChannel = NotificationChannel(
                    MINING_PROGRESS_CHANNEL,
                    "Mining Progress",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Notifications for mining job progress"
                    enableLights(false)
                    enableVibration(false)
                }
                
                // Register the channels with the system
                val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                notificationManager.createNotificationChannel(miningCompletionChannel)
                notificationManager.createNotificationChannel(miningProgressChannel)
                
                Log.d("MinerApp", "Notification channels created successfully")
            } catch (e: Exception) {
                Log.e("MinerApp", "Error creating notification channels: ${e.message}")
            }
        }
    }
}
