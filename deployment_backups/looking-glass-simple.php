<?php
// Simple Looking Glass for BIRD

// Header
echo '<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AS27218 Infinitum Nihil Looking Glass</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; line-height: 1.6; }
        h1, h2 { color: #0064c1; }
        pre { background-color: #f5f5f5; padding: 15px; border-radius: 5px; overflow: auto; white-space: pre-wrap; }
        .container { max-width: 1200px; margin: 0 auto; }
        form { margin-bottom: 20px; }
        select, button { padding: 8px; margin: 5px 0; }
        button { background-color: #0064c1; color: white; border: none; cursor: pointer; }
        button:hover { background-color: #004e97; }
        .footer { margin-top: 30px; border-top: 1px solid #eee; padding-top: 20px; font-size: 0.9em; color: #666; }
    </style>
</head>
<body>
    <div class="container">
        <h1>AS27218 Infinitum Nihil Looking Glass</h1>
        <p>This service provides real-time visibility into our global BGP routing infrastructure. 
           You are currently connected to our <strong>Los Angeles (LAX)</strong> node.</p>
        
        <form>
            <select name="cmd" onchange="this.form.submit()">
                <option value="">Select a command</option>
                <option value="show_protocols">Show BGP Protocols</option>
                <option value="show_route_bgp">Show BGP Routes</option>
                <option value="show_route_ipv4">Show IPv4 Route for 192.30.120.0/23</option>
                <option value="show_route_ipv6">Show IPv6 Route for 2620:71:4000::/48</option>
                <option value="show_status">Show BIRD Status</option>
            </select>
        </form>';

// Process command if selected
if (isset($_GET['cmd'])) {
    $cmd = $_GET['cmd'];
    $bird_cmd = '';
    $title = '';

    // Map web commands to BIRD commands
    switch ($cmd) {
        case 'show_protocols':
            $bird_cmd = 'show protocols';
            $title = 'BGP Protocols';
            break;
        case 'show_route_bgp':
            $bird_cmd = 'show route where proto ~ "bgp*"';
            $title = 'BGP Routes';
            break;
        case 'show_route_ipv4':
            $bird_cmd = 'show route for 192.30.120.0/23';
            $title = 'IPv4 Route for 192.30.120.0/23';
            break;
        case 'show_route_ipv6':
            $bird_cmd = 'show route for 2620:71:4000::/48';
            $title = 'IPv6 Route for 2620:71:4000::/48';
            break;
        case 'show_status':
            $bird_cmd = 'show status';
            $title = 'BIRD Status';
            break;
        default:
            $bird_cmd = '';
            $title = 'Invalid Command';
    }

    if ($bird_cmd) {
        echo "<h2>{$title}</h2>";
        echo "<p>Executing command: <code>{$bird_cmd}</code></p>";
        echo "<pre>";
        
        // Execute the command with proper sanitization
        $safe_cmd = escapeshellarg($bird_cmd);
        $output = shell_exec("birdc $safe_cmd 2>&1");
        
        if (!$output) {
            echo "Error: Failed to execute command. Check if BIRD is running.";
        } else {
            echo htmlspecialchars($output);
        }
        
        echo "</pre>";
    }
} else {
    echo '<h2>Welcome to the BGP Looking Glass</h2>
    <p>Select a command from the dropdown menu above to view BGP information.</p>
    
    <h2>Network Information</h2>
    <ul>
        <li><strong>AS Number:</strong> 27218</li>
        <li><strong>Network:</strong> Infinitum Nihil, LLC</li>
        <li><strong>IPv4 Range:</strong> 192.30.120.0/23</li>
        <li><strong>IPv6 Range:</strong> 2620:71:4000::/48</li>
    </ul>';
}

// Footer
echo '
        <div class="footer">
            <p>AS27218 Infinitum Nihil Network &copy; 2025</p>
        </div>
    </div>
</body>
</html>';
?>
